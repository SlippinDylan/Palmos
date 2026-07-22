#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH PLIST_BUDDY

readonly REPOSITORY_ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly COMPANION_IDENTIFIER="com.palmos.smartservice.smartctl"
readonly LOCAL_SUPPORT_DIRECTORY="$REPOSITORY_ROOT/DerivedData/LocalSMART"
readonly SIGNED_COMPANION_DIRECTORY="$LOCAL_SUPPORT_DIRECTORY/SignedCompanions"
readonly TEMPORARY_DIRECTORY="$LOCAL_SUPPORT_DIRECTORY/Temporary"
readonly BUILD_LOCK_DIRECTORY="$LOCAL_SUPPORT_DIRECTORY/.build-local-smart-app.lock"
readonly DERIVED_DATA_PATH="${PALMOS_DERIVED_DATA_PATH:-$LOCAL_SUPPORT_DIRECTORY/AppBuild}"
readonly LOCAL_CONFIG_PATH="$REPOSITORY_ROOT/Config/xcconfigs/Local.xcconfig"
readonly COMPANION_BUILD_SCRIPT="$REPOSITORY_ROOT/Scripts/build-smartctl-companion.sh"
readonly CODE_SIGNING_VERIFIER="$REPOSITORY_ROOT/Scripts/verify/code-signing.sh"

requested_identity="${PALMOS_SIGNING_IDENTITY:-}"
run_directory=""
local_config_temporary=""
lock_acquired=false

usage() {
  /bin/cat <<'EOF'
Usage: Scripts/build-local-smart-app.sh [options]

Prepare Xcode for local SMART development and build a verified Release app.
An Apple Development identity from a free Personal Team is sufficient; paid
Developer ID distribution and notarization are not required.

Options:
  --identity SHA1       Select an Apple Development identity by its SHA-1 hash.
  -h, --help            Show this help.

Environment equivalents:
  PALMOS_SIGNING_IDENTITY
  PALMOS_DERIVED_DATA_PATH
  SMARTMONTOOLS_SOURCE_ARCHIVE

On success the script writes the git-ignored Config/xcconfigs/Local.xcconfig.
Subsequent Xcode Cmd+R builds will use the same Personal Team and companion.
Each run rebuilds smartctl from the pinned, SHA-verified source archive.
EOF
}

fail() {
  echo "Local SMART build failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$local_config_temporary" && -f "$local_config_temporary" && ! -L "$local_config_temporary" ]]; then
    /bin/rm -f -- "$local_config_temporary"
  fi
  if [[ -n "$run_directory" && -d "$run_directory" && ! -L "$run_directory" ]]; then
    case "$run_directory" in
      "$TEMPORARY_DIRECTORY"/local-smart.*) /bin/rm -rf -- "$run_directory" ;;
    esac
  fi
  if [[ "$lock_acquired" == true && -d "$BUILD_LOCK_DIRECTORY" && ! -L "$BUILD_LOCK_DIRECTORY" ]]; then
    /bin/rmdir "$BUILD_LOCK_DIRECTORY" 2>/dev/null || true
  fi
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || fail "$option requires a value"
}

prepare_private_directory() {
  local path="$1"
  local owner_id
  local resolved_path

  [[ ! -L "$path" ]] || fail "refusing symbolic-link directory at $path"
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || fail "expected a directory at $path"
  else
    /bin/mkdir -p -m 0700 "$path"
  fi
  owner_id="$(/usr/bin/stat -f%u "$path")"
  [[ "$owner_id" == "$EUID" ]] || fail "directory is not owned by the current user: $path"
  resolved_path="$(cd "$path" && pwd -P)"
  [[ "$resolved_path" == "$path" ]] \
    || fail "directory has a symbolic-link ancestor: $path"
  /bin/chmod 0700 "$path"
}

signature_field() {
  local path="$1"
  local field="$2"

  /usr/bin/codesign -d --verbose=4 "$path" 2>&1 \
    | /usr/bin/awk -F= -v field="$field" '
        $1 == field && !found {
          print substr($0, length(field) + 2)
          found = 1
        }
      '
}

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

assert_universal_companion() {
  local path="$1"
  local architectures

  architectures="$(/usr/bin/lipo -archs "$path")"
  for required_architecture in arm64 x86_64; do
    case " $architectures " in
      *" $required_architecture "*) ;;
      *) fail "smartctl architectures '$architectures' omit '$required_architecture'" ;;
    esac
  done
  for architecture in $architectures; do
    case "$architecture" in
      arm64|x86_64) ;;
      *) fail "smartctl contains unsupported architecture '$architecture'" ;;
    esac
  done
}

validate_signed_companion() {
  local path="$1"
  local expected_sha256="$2"
  local expected_team_id="$3"
  local actual_identifier
  local actual_team_id

  [[ -f "$path" && ! -L "$path" ]] || fail "signed companion is not a regular file at $path"
  [[ "$(sha256 "$path")" == "$expected_sha256" ]] \
    || fail "signed companion content does not match its immutable path"
  /usr/bin/codesign --verify --strict --all-architectures --verbose=2 "$path"
  actual_identifier="$(signature_field "$path" Identifier)"
  actual_team_id="$(signature_field "$path" TeamIdentifier)"
  [[ "$actual_identifier" == "$COMPANION_IDENTIFIER" ]] \
    || fail "signed companion identifier is '$actual_identifier', expected '$COMPANION_IDENTIFIER'"
  [[ "$actual_team_id" == "$expected_team_id" ]] \
    || fail "signed companion TeamIdentifier '$actual_team_id' does not match '$expected_team_id'"
  [[ "$(/usr/bin/stat -f%Lp "$path")" == 500 ]] \
    || fail "immutable companion permissions changed at $path"
  [[ "$(/usr/bin/stat -f%Lp "${path%/*}")" == 700 ]] \
    || fail "immutable companion directory permissions changed at ${path%/*}"
  assert_universal_companion "$path"
}

while (($# > 0)); do
  case "$1" in
    --identity)
      require_value "$1" "${2:-}"
      requested_identity="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option '$1'"
      ;;
  esac
done

if [[ -n "$requested_identity" ]]; then
  requested_identity="$(/usr/bin/tr '[:lower:]' '[:upper:]' <<< "$requested_identity" | /usr/bin/tr -d '[:space:]')"
  [[ "$requested_identity" =~ ^[[:xdigit:]]{40}$ ]] \
    || fail "identity must be a 40-character SHA-1 hash from security find-identity"
fi

[[ "$DERIVED_DATA_PATH" == /* ]] \
  || fail "PALMOS_DERIVED_DATA_PATH must be an absolute path"
[[ ! -L "$DERIVED_DATA_PATH" ]] \
  || fail "PALMOS_DERIVED_DATA_PATH must not be a symbolic link"
case "$DERIVED_DATA_PATH" in
  /|"$REPOSITORY_ROOT"|"$REPOSITORY_ROOT/Config"|"$LOCAL_SUPPORT_DIRECTORY"|"$SIGNED_COMPANION_DIRECTORY"|"$TEMPORARY_DIRECTORY")
    fail "PALMOS_DERIVED_DATA_PATH is too broad or overlaps protected build state"
    ;;
esac
case "$REPOSITORY_ROOT/" in
  "$DERIVED_DATA_PATH"/*) fail "PALMOS_DERIVED_DATA_PATH must not be an ancestor of the repository" ;;
esac
[[ ! -L "$LOCAL_CONFIG_PATH" ]] \
  || fail "refusing symbolic-link Local.xcconfig at $LOCAL_CONFIG_PATH"
if [[ -e "$LOCAL_CONFIG_PATH" ]]; then
  [[ -f "$LOCAL_CONFIG_PATH" ]] || fail "Local.xcconfig is not a regular file"
fi

identity_output="$(/usr/bin/security find-identity -v -p codesigning)"
apple_development_identities="$(/usr/bin/awk '/"Apple Development:/ { print }' <<< "$identity_output")"

if [[ -n "$requested_identity" ]]; then
  selected_identity_line="$(/usr/bin/awk -v identity="$requested_identity" '
      toupper($2) == identity && !found {
        print
        found = 1
      }
    ' <<< "$apple_development_identities")"
  [[ -n "$selected_identity_line" ]] || fail \
    "the requested SHA-1 is not a valid Apple Development identity"
else
  identity_count="$(/usr/bin/awk 'NF { count += 1 } END { print count + 0 }' <<< "$apple_development_identities")"
  case "$identity_count" in
    0)
      fail "no valid Apple Development identity was found. Open Xcode > Settings > Accounts > Manage Certificates and create one for your free Personal Team, then rerun this script."
      ;;
    1)
      selected_identity_line="$apple_development_identities"
      ;;
    *)
      echo "$apple_development_identities" >&2
      fail "multiple Apple Development identities are available; select one with --identity SHA1"
      ;;
  esac
fi

signing_identity="$(/usr/bin/awk '{ print $2 }' <<< "$selected_identity_line")"
signing_certificate_name="$(/usr/bin/sed -E 's/^[^"]*"([^"]+)".*$/\1/' <<< "$selected_identity_line")"
[[ "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]] \
  || fail "could not parse the selected Apple Development identity hash"

prepare_private_directory "$LOCAL_SUPPORT_DIRECTORY"
prepare_private_directory "$SIGNED_COMPANION_DIRECTORY"
prepare_private_directory "$TEMPORARY_DIRECTORY"
if ! /bin/mkdir -m 0700 "$BUILD_LOCK_DIRECTORY" 2>/dev/null; then
  fail "another local SMART build is running, or a stale lock exists at $BUILD_LOCK_DIRECTORY. If no build is running, remove that empty directory and retry."
fi
lock_acquired=true

run_directory="$(/usr/bin/mktemp -d "$TEMPORARY_DIRECTORY/local-smart.XXXXXX")"
case "$run_directory" in
  "$TEMPORARY_DIRECTORY"/local-smart.*) ;;
  *) fail "mktemp returned an unexpected path: $run_directory" ;;
esac
[[ -d "$run_directory" && ! -L "$run_directory" ]] \
  || fail "temporary build directory is unsafe: $run_directory"

readonly COMPANION_BUILD_OUTPUT="$run_directory/build-output"
export TMPDIR="$TEMPORARY_DIRECTORY"
unset SDKROOT MACOSX_DEPLOYMENT_TARGET SMARTCTL_BUILD_ARCHS
"$COMPANION_BUILD_SCRIPT" "$COMPANION_BUILD_OUTPUT"

readonly UNSIGNED_COMPANION_PATH="$COMPANION_BUILD_OUTPUT/smartctl"
readonly COMPANION_LICENSE_PATH="$COMPANION_BUILD_OUTPUT/smartmontools-COPYING.txt"
[[ -f "$UNSIGNED_COMPANION_PATH" && ! -L "$UNSIGNED_COMPANION_PATH" ]] \
  || fail "builder did not produce a regular smartctl companion"
/usr/bin/cmp \
  "$COMPANION_LICENSE_PATH" \
  "$REPOSITORY_ROOT/Shared/Licensing/smartmontools-COPYING.txt"
assert_universal_companion "$UNSIGNED_COMPANION_PATH"

companion_size="$(/usr/bin/stat -f%z "$UNSIGNED_COMPANION_PATH")"
(( companion_size > 0 && companion_size <= 8 * 1024 * 1024 )) \
  || fail "smartctl size '$companion_size' exceeds the 8 MiB installation limit"
if /usr/bin/otool -L "$UNSIGNED_COMPANION_PATH" | /usr/bin/grep -Eq '/(opt/homebrew|usr/local)/'; then
  fail "smartctl links a user-writable Homebrew or /usr/local library"
fi
if /usr/bin/strings -a "$UNSIGNED_COMPANION_PATH" | /usr/bin/grep -Eq '/(opt/homebrew|usr/local)/'; then
  fail "smartctl contains a user-writable Homebrew or /usr/local runtime path"
fi
smartctl_version_output="$("$UNSIGNED_COMPANION_PATH" --version)"
smartctl_version="${smartctl_version_output%%$'\n'*}"
case "$smartctl_version" in
  "smartctl 7.5 "*) ;;
  *) fail "built companion reported unexpected version: $smartctl_version" ;;
esac

readonly SIGNED_STAGING_DIRECTORY="$run_directory/signed-companion"
/bin/mkdir -m 0700 "$SIGNED_STAGING_DIRECTORY"
readonly SIGNED_STAGING_PATH="$SIGNED_STAGING_DIRECTORY/smartctl"
/bin/cp -p "$UNSIGNED_COMPANION_PATH" "$SIGNED_STAGING_PATH"
/bin/chmod 0755 "$SIGNED_STAGING_PATH"

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --identifier "$COMPANION_IDENTIFIER" \
  --options runtime \
  --timestamp=none \
  "$SIGNED_STAGING_PATH"
/usr/bin/codesign --verify --strict --all-architectures --verbose=2 "$SIGNED_STAGING_PATH"

companion_identifier="$(signature_field "$SIGNED_STAGING_PATH" Identifier)"
signing_team_id="$(signature_field "$SIGNED_STAGING_PATH" TeamIdentifier)"
[[ "$companion_identifier" == "$COMPANION_IDENTIFIER" ]] \
  || fail "signed companion identifier is '$companion_identifier', expected '$COMPANION_IDENTIFIER'"
[[ "$signing_team_id" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "the selected identity did not produce a valid TeamIdentifier"

companion_sha256="$(sha256 "$SIGNED_STAGING_PATH")"
echo "Building Palmos with Apple Development identity: $signing_certificate_name"
/usr/bin/xcodebuild build \
  -workspace "$REPOSITORY_ROOT/Palmos.xcworkspace" \
  -scheme PalmosApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  DEVELOPMENT_TEAM="$signing_team_id" \
  TEAM_IDENTIFIER="$signing_team_id" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  SMARTCTL_COMPANION_PATH="$SIGNED_STAGING_PATH" \
  SMARTCTL_COMPANION_SHA256="$companion_sha256" \
  SMARTCTL_COMPANION_REQUIRED_FOR_SIGNED_BUILD=YES

readonly APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/PalmosApp.app"
"$CODE_SIGNING_VERIFIER" "$APP_PATH" "$signing_team_id"

readonly IMMUTABLE_COMPANION_DIRECTORY="$SIGNED_COMPANION_DIRECTORY/$companion_sha256"
readonly IMMUTABLE_COMPANION_PATH="$IMMUTABLE_COMPANION_DIRECTORY/smartctl"
if [[ -e "$IMMUTABLE_COMPANION_DIRECTORY" || -L "$IMMUTABLE_COMPANION_DIRECTORY" ]]; then
  [[ -d "$IMMUTABLE_COMPANION_DIRECTORY" && ! -L "$IMMUTABLE_COMPANION_DIRECTORY" ]] \
    || fail "immutable companion path is unsafe: $IMMUTABLE_COMPANION_DIRECTORY"
  validate_signed_companion "$IMMUTABLE_COMPANION_PATH" "$companion_sha256" "$signing_team_id"
else
  /bin/chmod 0500 "$SIGNED_STAGING_PATH"
  /bin/mv "$SIGNED_STAGING_DIRECTORY" "$IMMUTABLE_COMPANION_DIRECTORY"
  /bin/chmod 0700 "$IMMUTABLE_COMPANION_DIRECTORY"
  validate_signed_companion "$IMMUTABLE_COMPANION_PATH" "$companion_sha256" "$signing_team_id"
fi

local_config_temporary="$(/usr/bin/mktemp "$LOCAL_CONFIG_PATH.tmp.XXXXXX")"
case "$local_config_temporary" in
  "$LOCAL_CONFIG_PATH".tmp.*) ;;
  *) fail "mktemp returned an unexpected local config path: $local_config_temporary" ;;
esac
/bin/cat > "$local_config_temporary" <<EOF
// Generated by Scripts/build-local-smart-app.sh. Do not commit.
DEVELOPMENT_TEAM = $signing_team_id
TEAM_IDENTIFIER = \$(DEVELOPMENT_TEAM)
SMARTCTL_COMPANION_PATH = \$(SRCROOT)/DerivedData/LocalSMART/SignedCompanions/$companion_sha256/smartctl
SMARTCTL_COMPANION_SHA256 = $companion_sha256
SMARTCTL_COMPANION_REQUIRED_FOR_SIGNED_BUILD = YES
EOF
/bin/chmod 0600 "$local_config_temporary"
/bin/mv -f "$local_config_temporary" "$LOCAL_CONFIG_PATH"
local_config_temporary=""

printf '\nConfigured Xcode with Personal Team %s.\n' "$signing_team_id"
printf 'Built and verified:\n  %s\n\n' "$APP_PATH"
printf 'You can launch this build with:\n  open %q\n\n' "$APP_PATH"
printf 'Future Xcode Cmd+R builds will reuse Config/xcconfigs/Local.xcconfig.\n'
