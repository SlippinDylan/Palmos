#!/bin/bash

set -euo pipefail

readonly APP_PATH="${1:?Usage: code-signing.sh <app-path> [expected-team-id]}"
readonly EXPECTED_TEAM_ID="${2:-}"
readonly APP_IDENTIFIER="com.drivepulse.app"
readonly HELPER_IDENTIFIER="com.drivepulse.smartservice"
readonly HELPER_PATH="$APP_PATH/Contents/Library/LaunchServices/$HELPER_IDENTIFIER"
readonly COMPANION_IDENTIFIER="com.drivepulse.smartservice.smartctl"
readonly COMPANION_PATH="$APP_PATH/Contents/Library/Helpers/$COMPANION_IDENTIFIER"
readonly SMARTMONTOOLS_LICENSE_PATH="$APP_PATH/Contents/Resources/smartmontools-COPYING.txt"
readonly SMARTMONTOOLS_LICENSE_SHA256="8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
readonly APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"

fail() {
  echo "Code-signing verification failed: $*" >&2
  exit 1
}

signature_field() {
  local path="$1"
  local field="$2"

  codesign -d --verbose=4 "$path" 2>&1 \
    | awk -F= -v field="$field" '
        $1 == field && !found {
          print substr($0, length(field) + 2)
          found = 1
        }
      '
}

[[ -d "$APP_PATH" ]] || fail "app bundle not found at $APP_PATH"
[[ -f "$HELPER_PATH" ]] || fail "embedded helper not found at $HELPER_PATH"
[[ -f "$COMPANION_PATH" ]] || fail "embedded smartctl companion not found at $COMPANION_PATH"
[[ -f "$SMARTMONTOOLS_LICENSE_PATH" ]] \
  || fail "bundled smartmontools license not found at $SMARTMONTOOLS_LICENSE_PATH"
[[ -f "$APP_INFO_PLIST" ]] || fail "app Info.plist not found at $APP_INFO_PLIST"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$HELPER_PATH"
codesign --verify --strict --verbose=2 "$COMPANION_PATH"

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
[[ -n "$app_team_id" && "$app_team_id" != "not set" ]] \
  || fail "app does not have a TeamIdentifier"
[[ "$helper_team_id" == "$app_team_id" ]] \
  || fail "app TeamIdentifier '$app_team_id' does not match helper TeamIdentifier '$helper_team_id'"
[[ "$companion_team_id" == "$app_team_id" ]] \
  || fail "app TeamIdentifier '$app_team_id' does not match companion TeamIdentifier '$companion_team_id'"

companion_architectures="$(lipo -archs "$COMPANION_PATH")"
companion_size="$(stat -f%z "$COMPANION_PATH")"
(( companion_size > 0 && companion_size <= 8 * 1024 * 1024 )) \
  || fail "companion size '$companion_size' exceeds the 8 MiB installation limit"
for required_architecture in arm64 x86_64; do
  case " $companion_architectures " in
    *" $required_architecture "*) ;;
    *) fail "companion architectures '$companion_architectures' do not include $required_architecture" ;;
  esac
done

app_architectures="$(lipo -archs "$APP_PATH/Contents/MacOS/DrivePulseApp")"
for architecture in $app_architectures; do
  case " $companion_architectures " in
    *" $architecture "*) ;;
    *) fail "companion architectures '$companion_architectures' do not match app architecture '$architecture'" ;;
  esac
done
for architecture in $companion_architectures; do
  case " $app_architectures " in
    *" $architecture "*) ;;
    *) fail "app architectures '$app_architectures' do not match companion architecture '$architecture'" ;;
  esac
done

if otool -L "$COMPANION_PATH" | rg -q '/(opt/homebrew|usr/local)/'; then
  fail "companion links a user-writable Homebrew or /usr/local library"
fi
if strings -a "$COMPANION_PATH" | rg -q '/(opt/homebrew|usr/local)/'; then
  fail "companion contains a user-writable Homebrew or /usr/local runtime path"
fi

license_sha256="$(shasum -a 256 "$SMARTMONTOOLS_LICENSE_PATH" | awk '{ print $1 }')"
[[ "$license_sha256" == "$SMARTMONTOOLS_LICENSE_SHA256" ]] \
  || fail "bundled smartmontools license SHA-256 is '$license_sha256', expected '$SMARTMONTOOLS_LICENSE_SHA256'"

if [[ -n "$EXPECTED_TEAM_ID" && "$app_team_id" != "$EXPECTED_TEAM_ID" ]]; then
  fail "signed TeamIdentifier '$app_team_id' does not match expected Team ID '$EXPECTED_TEAM_ID'"
fi

helper_requirement="$(
  /usr/libexec/PlistBuddy \
    -c "Print :SMPrivilegedExecutables:$HELPER_IDENTIFIER" \
    "$APP_INFO_PLIST"
)"

helper_info_plist="$(mktemp)"
requirement_binary="$(mktemp)"
trap 'rm -f "$helper_info_plist" "$requirement_binary"' EXIT
machine_arch="$(uname -m)"
case "$machine_arch" in
  arm64|arm64e) machine_arch="arm64" ;;
  x86_64) ;;
  *) fail "unsupported verification architecture '$machine_arch'" ;;
esac

info_plist_hex="$(otool -arch "$machine_arch" -X -s __TEXT __info_plist "$HELPER_PATH" \
  | awk '
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
[[ -n "$info_plist_hex" ]] || fail "embedded helper __info_plist section is empty"
printf '%s\n' "$info_plist_hex" | xxd -r -p > "$helper_info_plist"
plutil -lint "$helper_info_plist" >/dev/null

companion_requirement="$(${PLIST_BUDDY:-/usr/libexec/PlistBuddy} \
  -c "Print :DrivePulseSmartctlCompanionRequirement" \
  "$helper_info_plist")"
[[ -n "$companion_requirement" ]] \
  || fail "helper contains an empty smartctl companion requirement"
csreq -r "=$companion_requirement" -b "$requirement_binary" >/dev/null 2>&1 \
  || fail "helper contains an invalid smartctl companion requirement"
codesign --verify --strict -R="$companion_requirement" "$COMPANION_PATH"

expected_companion_sha256="$(${PLIST_BUDDY:-/usr/libexec/PlistBuddy} \
  -c "Print :DrivePulseSmartctlCompanionSHA256" \
  "$helper_info_plist")"
actual_companion_sha256="$(shasum -a 256 "$COMPANION_PATH" | awk '{ print $1 }')"
[[ "$expected_companion_sha256" =~ ^[[:xdigit:]]{64}$ ]] \
  || fail "helper contains an invalid smartctl companion SHA-256"
[[ "$actual_companion_sha256" == "$expected_companion_sha256" ]] \
  || fail "companion SHA-256 '$actual_companion_sha256' does not match helper expectation '$expected_companion_sha256'"

app_requirements=()
requirement_index=0
while app_requirement="$(
  /usr/libexec/PlistBuddy \
    -c "Print :SMAuthorizedClients:$requirement_index" \
    "$helper_info_plist" 2>/dev/null
)"; do
  [[ -n "$app_requirement" ]] \
    || fail "helper contains an empty SMAuthorizedClients requirement at index $requirement_index"
  app_requirements+=("$app_requirement")
  ((requirement_index += 1))
done

((${#app_requirements[@]} > 0)) \
  || fail "helper does not contain an SMAuthorizedClients requirement"

for app_requirement in "${app_requirements[@]}"; do
  csreq -r "=$app_requirement" -b "$requirement_binary" >/dev/null 2>&1 \
    || fail "helper contains an invalid SMAuthorizedClients requirement"
done

codesign --verify --strict -R="$helper_requirement" "$HELPER_PATH"

app_requirement_matched=false
for app_requirement in "${app_requirements[@]}"; do
  if codesign --verify --strict -R="$app_requirement" "$APP_PATH" >/dev/null 2>&1; then
    app_requirement_matched=true
    break
  fi
done

[[ "$app_requirement_matched" == true ]] \
  || fail "none of the helper SMAuthorizedClients requirements accepts the app"

echo "Verified DrivePulse app and helper signatures for Team ID $app_team_id."
