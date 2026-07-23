#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH PLIST_BUDDY

readonly APP_PATH="${1:?Usage: code-signing.sh <app-path> [expected-team-id]}"
readonly EXPECTED_TEAM_ID="${2:-}"
readonly APP_IDENTIFIER="com.palmos.app"
readonly HELPER_IDENTIFIER="com.palmos.smartservice"
readonly APP_EXECUTABLE="$APP_PATH/Contents/MacOS/PalmosApp"
readonly HELPER_PATH="$APP_PATH/Contents/Library/LaunchServices/$HELPER_IDENTIFIER"
readonly COMPANION_IDENTIFIER="com.palmos.smartservice.smartctl"
readonly COMPANION_PATH="$APP_PATH/Contents/Library/Helpers/$COMPANION_IDENTIFIER"
readonly PALMOS_LICENSE_PATH="$APP_PATH/Contents/Resources/LICENSE"
readonly PALMOS_LICENSE_SHA256="054515e39d8e9ec2004aeafc2aba2700aad7f7c94041c43fd316ac998c822b59"
readonly MENUBAREXTRAACCESS_LICENSE_PATH="$APP_PATH/Contents/Resources/MenuBarExtraAccess-LICENSE.txt"
readonly MENUBAREXTRAACCESS_LICENSE_SHA256="c5359afef4354cebfefe6632278be29f6607fb6f4bd35c07028c9a7a639eebf3"
readonly SMARTMONTOOLS_LICENSE_PATH="$APP_PATH/Contents/Resources/smartmontools-COPYING.txt"
readonly SMARTMONTOOLS_LICENSE_SHA256="8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
readonly APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"

verification_directory=""

fail() {
  echo "Code-signing verification failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$verification_directory" && -d "$verification_directory" && ! -L "$verification_directory" ]]; then
    case "$verification_directory" in
      "${TMPDIR:-/tmp}"/palmos-signing-verify.*) /bin/rm -rf -- "$verification_directory" ;;
    esac
  fi
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

signature_field() {
  local path="$1"
  local field="$2"
  local architecture="${3:-}"
  local arguments=(-d --verbose=4)

  if [[ -n "$architecture" ]]; then
    arguments+=(--architecture "$architecture")
  fi
  /usr/bin/codesign "${arguments[@]}" "$path" 2>&1 \
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

contains_architecture() {
  local architectures="$1"
  local expected="$2"

  case " $architectures " in
    *" $expected "*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_same_architectures() {
  local left_name="$1"
  local left_architectures="$2"
  local right_name="$3"
  local right_architectures="$4"

  for architecture in $left_architectures; do
    contains_architecture "$right_architectures" "$architecture" \
      || fail "$left_name architectures '$left_architectures' do not match $right_name architectures '$right_architectures'"
  done
  for architecture in $right_architectures; do
    contains_architecture "$left_architectures" "$architecture" \
      || fail "$left_name architectures '$left_architectures' do not match $right_name architectures '$right_architectures'"
  done
}

extract_helper_info_plist() {
  local architecture="$1"
  local output_path="$2"
  local info_plist_hex

  info_plist_hex="$(/usr/bin/otool -arch "$architecture" -X -s __TEXT __info_plist "$HELPER_PATH" \
    | /usr/bin/awk '
        {
          for (field_index = 2; field_index <= NF; field_index++) {
            word = $field_index
            if (length(word) == 2 && word !~ /[^[:xdigit:]]/) {
              print word
            } else if (length(word) == 8 && word !~ /[^[:xdigit:]]/) {
              print substr(word, 7, 2) substr(word, 5, 2) substr(word, 3, 2) substr(word, 1, 2)
            }
          }
        }
      ')"
  [[ -n "$info_plist_hex" ]] \
    || fail "embedded helper __info_plist section is empty for architecture '$architecture'"
  /usr/bin/printf '%s\n' "$info_plist_hex" | /usr/bin/xxd -r -p > "$output_path"
  /usr/bin/plutil -lint "$output_path" >/dev/null \
    || fail "embedded helper Info.plist is invalid for architecture '$architecture'"
}

[[ -d "$APP_PATH" ]] || fail "app bundle not found at $APP_PATH"
[[ -f "$APP_EXECUTABLE" && ! -L "$APP_EXECUTABLE" ]] \
  || fail "app executable not found at $APP_EXECUTABLE"
[[ -f "$HELPER_PATH" && ! -L "$HELPER_PATH" ]] \
  || fail "embedded helper not found at $HELPER_PATH"
[[ -f "$COMPANION_PATH" && ! -L "$COMPANION_PATH" ]] \
  || fail "embedded smartctl companion not found at $COMPANION_PATH"
[[ -f "$PALMOS_LICENSE_PATH" && ! -L "$PALMOS_LICENSE_PATH" ]] \
  || fail "bundled Palmos license not found at $PALMOS_LICENSE_PATH"
[[ -f "$MENUBAREXTRAACCESS_LICENSE_PATH" && ! -L "$MENUBAREXTRAACCESS_LICENSE_PATH" ]] \
  || fail "bundled MenuBarExtraAccess license not found at $MENUBAREXTRAACCESS_LICENSE_PATH"
[[ -f "$SMARTMONTOOLS_LICENSE_PATH" && ! -L "$SMARTMONTOOLS_LICENSE_PATH" ]] \
  || fail "bundled smartmontools license not found at $SMARTMONTOOLS_LICENSE_PATH"
[[ -f "$APP_INFO_PLIST" && ! -L "$APP_INFO_PLIST" ]] \
  || fail "app Info.plist not found at $APP_INFO_PLIST"

/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "$APP_PATH"
/usr/bin/codesign --verify --strict --all-architectures --verbose=2 "$HELPER_PATH"
/usr/bin/codesign --verify --strict --all-architectures --verbose=2 "$COMPANION_PATH"

app_identifier="$(signature_field "$APP_PATH" Identifier)"
helper_identifier="$(signature_field "$HELPER_PATH" Identifier)"
companion_identifier="$(signature_field "$COMPANION_PATH" Identifier)"
app_team_id="$(signature_field "$APP_PATH" TeamIdentifier)"
helper_team_id="$(signature_field "$HELPER_PATH" TeamIdentifier)"
companion_team_id="$(signature_field "$COMPANION_PATH" TeamIdentifier)"

[[ "$app_identifier" == "$APP_IDENTIFIER" ]] \
  || fail "app identifier is '$app_identifier', expected '$APP_IDENTIFIER'"
[[ "$helper_identifier" == "$HELPER_IDENTIFIER" ]] \
  || fail "helper identifier is '$helper_identifier', expected '$HELPER_IDENTIFIER'"
[[ "$companion_identifier" == "$COMPANION_IDENTIFIER" ]] \
  || fail "companion identifier is '$companion_identifier', expected '$COMPANION_IDENTIFIER'"
[[ "$app_team_id" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "app does not have a valid TeamIdentifier"
[[ "$helper_team_id" == "$app_team_id" ]] \
  || fail "app TeamIdentifier '$app_team_id' does not match helper TeamIdentifier '$helper_team_id'"
[[ "$companion_team_id" == "$app_team_id" ]] \
  || fail "app TeamIdentifier '$app_team_id' does not match companion TeamIdentifier '$companion_team_id'"

app_architectures="$(/usr/bin/lipo -archs "$APP_EXECUTABLE")"
helper_architectures="$(/usr/bin/lipo -archs "$HELPER_PATH")"
companion_architectures="$(/usr/bin/lipo -archs "$COMPANION_PATH")"
assert_same_architectures "app" "$app_architectures" "helper" "$helper_architectures"
assert_same_architectures "app" "$app_architectures" "companion" "$companion_architectures"
for required_architecture in arm64 x86_64; do
  contains_architecture "$app_architectures" "$required_architecture" \
    || fail "release architectures '$app_architectures' do not include '$required_architecture'"
done
for architecture in $app_architectures; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) fail "release bundle contains unsupported architecture '$architecture'" ;;
  esac
done

for architecture in $app_architectures; do
  [[ "$(signature_field "$APP_PATH" Identifier "$architecture")" == "$APP_IDENTIFIER" ]] \
    || fail "app identifier differs in architecture '$architecture'"
  [[ "$(signature_field "$HELPER_PATH" Identifier "$architecture")" == "$HELPER_IDENTIFIER" ]] \
    || fail "helper identifier differs in architecture '$architecture'"
  [[ "$(signature_field "$COMPANION_PATH" Identifier "$architecture")" == "$COMPANION_IDENTIFIER" ]] \
    || fail "companion identifier differs in architecture '$architecture'"
  [[ "$(signature_field "$APP_PATH" TeamIdentifier "$architecture")" == "$app_team_id" ]] \
    || fail "app TeamIdentifier differs in architecture '$architecture'"
  [[ "$(signature_field "$HELPER_PATH" TeamIdentifier "$architecture")" == "$app_team_id" ]] \
    || fail "helper TeamIdentifier differs in architecture '$architecture'"
  [[ "$(signature_field "$COMPANION_PATH" TeamIdentifier "$architecture")" == "$app_team_id" ]] \
    || fail "companion TeamIdentifier differs in architecture '$architecture'"
done

companion_size="$(/usr/bin/stat -f%z "$COMPANION_PATH")"
(( companion_size > 0 && companion_size <= 8 * 1024 * 1024 )) \
  || fail "companion size '$companion_size' exceeds the 8 MiB installation limit"
if /usr/bin/otool -L "$COMPANION_PATH" | /usr/bin/grep -Eq '/(opt/homebrew|usr/local)/'; then
  fail "companion links a user-writable Homebrew or /usr/local library"
fi
if /usr/bin/strings -a "$COMPANION_PATH" | /usr/bin/grep -Eq '/(opt/homebrew|usr/local)/'; then
  fail "companion contains a user-writable Homebrew or /usr/local runtime path"
fi
smartctl_version_output="$("$COMPANION_PATH" --version)"
smartctl_version="${smartctl_version_output%%$'\n'*}"
case "$smartctl_version" in
  "smartctl 7.5 "*) ;;
  *) fail "companion reported unexpected version: $smartctl_version" ;;
esac

palmos_license_sha256="$(sha256 "$PALMOS_LICENSE_PATH")"
[[ "$palmos_license_sha256" == "$PALMOS_LICENSE_SHA256" ]] \
  || fail "bundled Palmos license SHA-256 is '$palmos_license_sha256', expected '$PALMOS_LICENSE_SHA256'"
menubarextraaccess_license_sha256="$(sha256 "$MENUBAREXTRAACCESS_LICENSE_PATH")"
[[ "$menubarextraaccess_license_sha256" == "$MENUBAREXTRAACCESS_LICENSE_SHA256" ]] \
  || fail "bundled MenuBarExtraAccess license SHA-256 is '$menubarextraaccess_license_sha256', expected '$MENUBAREXTRAACCESS_LICENSE_SHA256'"
smartmontools_license_sha256="$(sha256 "$SMARTMONTOOLS_LICENSE_PATH")"
[[ "$smartmontools_license_sha256" == "$SMARTMONTOOLS_LICENSE_SHA256" ]] \
  || fail "bundled smartmontools license SHA-256 is '$smartmontools_license_sha256', expected '$SMARTMONTOOLS_LICENSE_SHA256'"

if [[ -n "$EXPECTED_TEAM_ID" && "$app_team_id" != "$EXPECTED_TEAM_ID" ]]; then
  fail "signed TeamIdentifier '$app_team_id' does not match expected Team ID '$EXPECTED_TEAM_ID'"
fi

helper_requirement="$(
  /usr/libexec/PlistBuddy \
    -c "Print :SMPrivilegedExecutables:$HELPER_IDENTIFIER" \
    "$APP_INFO_PLIST"
)"
[[ -n "$helper_requirement" ]] || fail "app contains an empty helper requirement"

verification_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/palmos-signing-verify.XXXXXX")"
case "$verification_directory" in
  "${TMPDIR:-/tmp}"/palmos-signing-verify.*) ;;
  *) fail "mktemp returned an unexpected verification path: $verification_directory" ;;
esac
[[ -d "$verification_directory" && ! -L "$verification_directory" ]] \
  || fail "temporary verification directory is unsafe: $verification_directory"
readonly REQUIREMENT_BINARY="$verification_directory/requirement.bin"

/usr/bin/csreq -r "=$helper_requirement" -b "$REQUIREMENT_BINARY" >/dev/null 2>&1 \
  || fail "app contains an invalid SMPrivilegedExecutables requirement"
/usr/bin/codesign --verify --strict --all-architectures -R="$helper_requirement" "$HELPER_PATH"

actual_companion_sha256="$(sha256 "$COMPANION_PATH")"
baseline_security_manifest=""

for architecture in $helper_architectures; do
  helper_info_plist="$verification_directory/helper-$architecture.plist"
  extract_helper_info_plist "$architecture" "$helper_info_plist"

  companion_requirement="$(/usr/libexec/PlistBuddy \
    -c "Print :PalmosSmartctlCompanionRequirement" \
    "$helper_info_plist")"
  [[ -n "$companion_requirement" ]] \
    || fail "helper contains an empty smartctl companion requirement in architecture '$architecture'"
  /usr/bin/csreq -r "=$companion_requirement" -b "$REQUIREMENT_BINARY" >/dev/null 2>&1 \
    || fail "helper contains an invalid smartctl companion requirement in architecture '$architecture'"
  /usr/bin/codesign --verify --strict --all-architectures -R="$companion_requirement" "$COMPANION_PATH"

  expected_companion_sha256="$(/usr/libexec/PlistBuddy \
    -c "Print :PalmosSmartctlCompanionSHA256" \
    "$helper_info_plist")"
  [[ "$expected_companion_sha256" =~ ^[[:xdigit:]]{64}$ ]] \
    || fail "helper contains an invalid smartctl companion SHA-256 in architecture '$architecture'"
  [[ "$actual_companion_sha256" == "$expected_companion_sha256" ]] \
    || fail "companion SHA-256 '$actual_companion_sha256' does not match helper architecture '$architecture' expectation '$expected_companion_sha256'"

  app_requirements=()
  requirement_index=0
  while app_requirement="$(
    /usr/libexec/PlistBuddy \
      -c "Print :SMAuthorizedClients:$requirement_index" \
      "$helper_info_plist" 2>/dev/null
  )"; do
    [[ -n "$app_requirement" ]] \
      || fail "helper contains an empty SMAuthorizedClients requirement at index $requirement_index in architecture '$architecture'"
    app_requirements+=("$app_requirement")
    ((requirement_index += 1))
  done
  ((${#app_requirements[@]} > 0)) \
    || fail "helper does not contain an SMAuthorizedClients requirement in architecture '$architecture'"

  security_manifest="$(
    {
      /usr/bin/printf 'companion-requirement\0%s\0companion-sha256\0%s\0' \
        "$companion_requirement" "$expected_companion_sha256"
      for app_requirement in "${app_requirements[@]}"; do
        /usr/bin/printf 'authorized-client\0%s\0' "$app_requirement"
      done
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
  )"
  if [[ -z "$baseline_security_manifest" ]]; then
    baseline_security_manifest="$security_manifest"
  elif [[ "$security_manifest" != "$baseline_security_manifest" ]]; then
    fail "helper security fields differ between architecture slices"
  fi

  app_requirement_matched=false
  for app_requirement in "${app_requirements[@]}"; do
    /usr/bin/csreq -r "=$app_requirement" -b "$REQUIREMENT_BINARY" >/dev/null 2>&1 \
      || fail "helper contains an invalid SMAuthorizedClients requirement in architecture '$architecture'"
    if /usr/bin/codesign --verify --strict --all-architectures -R="$app_requirement" "$APP_PATH" >/dev/null 2>&1; then
      app_requirement_matched=true
    fi
  done
  [[ "$app_requirement_matched" == true ]] \
    || fail "none of the helper SMAuthorizedClients requirements accepts the app in architecture '$architecture'"
done

echo "Verified universal Palmos app, helper, and companion signatures for Team ID $app_team_id."
