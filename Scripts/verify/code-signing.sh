#!/bin/bash

set -euo pipefail

readonly APP_PATH="${1:?Usage: code-signing.sh <app-path> [expected-team-id]}"
readonly EXPECTED_TEAM_ID="${2:-}"
readonly APP_IDENTIFIER="com.drivepulse.app"
readonly HELPER_IDENTIFIER="com.drivepulse.smartservice"
readonly HELPER_PATH="$APP_PATH/Contents/Library/LaunchServices/$HELPER_IDENTIFIER"
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
[[ -f "$APP_INFO_PLIST" ]] || fail "app Info.plist not found at $APP_INFO_PLIST"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$HELPER_PATH"

app_identifier="$(signature_field "$APP_PATH" Identifier)"
helper_identifier="$(signature_field "$HELPER_PATH" Identifier)"
app_team_id="$(signature_field "$APP_PATH" TeamIdentifier)"
helper_team_id="$(signature_field "$HELPER_PATH" TeamIdentifier)"

[[ "$app_identifier" == "$APP_IDENTIFIER" ]] \
  || fail "app identifier is '$app_identifier', expected '$APP_IDENTIFIER'"
[[ "$helper_identifier" == "$HELPER_IDENTIFIER" ]] \
  || fail "helper identifier is '$helper_identifier', expected '$HELPER_IDENTIFIER'"
[[ -n "$app_team_id" && "$app_team_id" != "not set" ]] \
  || fail "app does not have a TeamIdentifier"
[[ "$helper_team_id" == "$app_team_id" ]] \
  || fail "app TeamIdentifier '$app_team_id' does not match helper TeamIdentifier '$helper_team_id'"

if [[ -n "$EXPECTED_TEAM_ID" && "$app_team_id" != "$EXPECTED_TEAM_ID" ]]; then
  fail "signed TeamIdentifier '$app_team_id' does not match expected Team ID '$EXPECTED_TEAM_ID'"
fi

helper_requirement="$(
  /usr/libexec/PlistBuddy \
    -c "Print :SMPrivilegedExecutables:$HELPER_IDENTIFIER" \
    "$APP_INFO_PLIST"
)"

helper_info_plist="$(mktemp)"
trap 'rm -f "$helper_info_plist"' EXIT
otool -X -s __TEXT __info_plist "$HELPER_PATH" \
  | awk '
      {
        for (field_index = 2; field_index <= NF; field_index++) {
          word = $field_index
          if (length(word) == 8 && word !~ /[^[:xdigit:]]/) {
            print substr(word, 7, 2) substr(word, 5, 2) substr(word, 3, 2) substr(word, 1, 2)
          }
        }
      }
    ' \
  | xxd -r -p > "$helper_info_plist"
plutil -lint "$helper_info_plist" >/dev/null

app_requirement="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :SMAuthorizedClients:0' \
    "$helper_info_plist"
)"

codesign --verify --strict -R="$helper_requirement" "$HELPER_PATH"
codesign --verify --strict -R="$app_requirement" "$APP_PATH"

echo "Verified DrivePulse app and helper signatures for Team ID $app_team_id."
