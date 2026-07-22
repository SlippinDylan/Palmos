#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH

readonly REPOSITORY_ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/palmos-local-smart-tests.XXXXXX")"
case "$work_directory" in
  "${TMPDIR:-/tmp}"/palmos-local-smart-tests.*) ;;
  *) echo "Unexpected test directory: $work_directory" >&2; exit 1 ;;
esac
cleanup() {
  /bin/chmod -R u+w "$work_directory" 2>/dev/null || true
  /bin/rm -rf -- "$work_directory"
}
trap cleanup EXIT

fail() {
  echo "Local SMART build regression failed: $*" >&2
  exit 1
}

assert_fails() {
  local expected_message="$1"
  shift
  local output

  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  case "$output" in
    *"$expected_message"*) ;;
    *) fail "failure output did not contain '$expected_message': $output" ;;
  esac
}

assert_file_unchanged() {
  local path="$1"
  local expected_sha256="$2"
  local actual_sha256

  actual_sha256="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{ print $1 }')"
  [[ "$actual_sha256" == "$expected_sha256" ]] \
    || fail "$path changed after a failed build"
}

readonly FIXTURE_ROOT="$work_directory/Palmos Fixture"
readonly MOCK_TOOLS="$FIXTURE_ROOT/mock tools"
readonly SCRIPT_UNDER_TEST="$FIXTURE_ROOT/Scripts/build-local-smart-app.sh"
readonly CONFIG_PATH="$FIXTURE_ROOT/Config/xcconfigs/Local.xcconfig"
readonly BUILDER_COUNT_PATH="$FIXTURE_ROOT/builder-count"

/bin/mkdir -p \
  "$MOCK_TOOLS" \
  "$FIXTURE_ROOT/Scripts/verify" \
  "$FIXTURE_ROOT/Config/xcconfigs" \
  "$FIXTURE_ROOT/Shared/Licensing"
/bin/cp "$REPOSITORY_ROOT/Shared/Licensing/smartmontools-COPYING.txt" \
  "$FIXTURE_ROOT/Shared/Licensing/smartmontools-COPYING.txt"

/usr/bin/sed \
  -e "s#/usr/bin/security#\"$MOCK_TOOLS/security\"#g" \
  -e "s#/usr/bin/codesign#\"$MOCK_TOOLS/codesign\"#g" \
  -e "s#/usr/bin/lipo#\"$MOCK_TOOLS/lipo\"#g" \
  -e "s#/usr/bin/otool#\"$MOCK_TOOLS/otool\"#g" \
  -e "s#/usr/bin/strings#\"$MOCK_TOOLS/strings\"#g" \
  -e "s#/usr/bin/xcodebuild#\"$MOCK_TOOLS/xcodebuild\"#g" \
  "$REPOSITORY_ROOT/Scripts/build-local-smart-app.sh" > "$SCRIPT_UNDER_TEST"

/bin/cat > "$MOCK_TOOLS/security" <<'EOF'
#!/bin/bash
printf '%s\n' "${MOCK_IDENTITIES:-}"
EOF

/bin/cat > "$MOCK_TOOLS/codesign" <<'EOF'
#!/bin/bash
set -euo pipefail
path=""
for argument in "$@"; do
  path="$argument"
done
case " $* " in
  *" -d "*)
    team="$(/usr/bin/awk -F: '/^signed-team:/ { print $2; exit }' "$path")"
    printf 'Identifier=com.palmos.smartservice.smartctl\n' >&2
    printf 'TeamIdentifier=%s\n' "$team" >&2
    ;;
  *" --force "*)
    [[ "${MOCK_CODESIGN_SIGN_FAIL:-0}" != 1 ]] || exit 41
    printf '\nsigned-team:%s\n' "${MOCK_TEAM:?}" >> "$path"
    ;;
  *" --verify "*)
    [[ "${MOCK_CODESIGN_VERIFY_FAIL:-0}" != 1 ]] || exit 42
    ;;
  *) exit 43 ;;
esac
EOF

/bin/cat > "$MOCK_TOOLS/lipo" <<'EOF'
#!/bin/bash
printf 'arm64 x86_64\n'
EOF

/bin/cat > "$MOCK_TOOLS/otool" <<'EOF'
#!/bin/bash
exit 0
EOF

/bin/cat > "$MOCK_TOOLS/strings" <<'EOF'
#!/bin/bash
exit 0
EOF

/bin/cat > "$MOCK_TOOLS/xcodebuild" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${MOCK_XCODEBUILD_FAIL:-0}" != 1 ]] || exit 51
derived_data_path=""
while (($# > 0)); do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data_path="$2"
    break
  fi
  shift
done
[[ -n "$derived_data_path" ]]
/bin/mkdir -p "$derived_data_path/Build/Products/Release/PalmosApp.app"
EOF

/bin/cat > "$FIXTURE_ROOT/Scripts/build-smartctl-companion.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${MOCK_BUILDER_FAIL:-0}" != 1 ]] || exit 31
if [[ -n "${SMARTMONTOOLS_SOURCE_ARCHIVE:-}" && ! -f "$SMARTMONTOOLS_SOURCE_ARCHIVE" ]]; then
  exit 32
fi
output_directory="$1"
count=0
if [[ -f "${MOCK_BUILDER_COUNT_PATH:?}" ]]; then
  count="$(/bin/cat "$MOCK_BUILDER_COUNT_PATH")"
fi
printf '%s\n' "$((count + 1))" > "$MOCK_BUILDER_COUNT_PATH"
/bin/mkdir -p "$output_directory"
/bin/cat > "$output_directory/smartctl" <<'SMARTCTL'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  echo "smartctl 7.5 mock"
fi
exit 0
SMARTCTL
/bin/chmod 0755 "$output_directory/smartctl"
/bin/cp "${MOCK_FIXTURE_ROOT:?}/Shared/Licensing/smartmontools-COPYING.txt" \
  "$output_directory/smartmontools-COPYING.txt"
EOF

/bin/cat > "$FIXTURE_ROOT/Scripts/verify/code-signing.sh" <<'EOF'
#!/bin/bash
[[ "${MOCK_VERIFIER_FAIL:-0}" != 1 ]] || exit 61
[[ -d "$1" ]]
[[ "$2" == "${MOCK_TEAM:?}" ]]
EOF

/bin/chmod 0755 \
  "$SCRIPT_UNDER_TEST" \
  "$MOCK_TOOLS/security" \
  "$MOCK_TOOLS/codesign" \
  "$MOCK_TOOLS/lipo" \
  "$MOCK_TOOLS/otool" \
  "$MOCK_TOOLS/strings" \
  "$MOCK_TOOLS/xcodebuild" \
  "$FIXTURE_ROOT/Scripts/build-smartctl-companion.sh" \
  "$FIXTURE_ROOT/Scripts/verify/code-signing.sh"

readonly IDENTITY_A="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
readonly IDENTITY_B="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
readonly TEAM_A="TEAMA12345"
readonly TEAM_B="TEAMB12345"
readonly IDENTITY_LINE_A="  1) $IDENTITY_A \"Apple Development: Test A\""
readonly IDENTITY_LINE_B="  1) $IDENTITY_B \"Apple Development: Test B\""
readonly COMMON_ENV=(
  "MOCK_BUILDER_COUNT_PATH=$BUILDER_COUNT_PATH"
  "MOCK_FIXTURE_ROOT=$FIXTURE_ROOT"
)

run_build() {
  local environment_arguments=()
  while (($# > 0)) && [[ "$1" != "--" ]]; do
    environment_arguments+=("$1")
    shift
  done
  if (($# > 0)); then
    shift
  fi
  /usr/bin/env "${COMMON_ENV[@]}" "${environment_arguments[@]}" "$SCRIPT_UNDER_TEST" "$@"
}

assert_fails "no valid Apple Development identity" \
  run_build MOCK_IDENTITIES= MOCK_TEAM="$TEAM_A"
[[ ! -e "$CONFIG_PATH" ]] || fail "zero-identity failure wrote Local.xcconfig"

assert_fails "multiple Apple Development identities" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_A
$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_A"
assert_fails "40-character SHA-1" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_A" MOCK_TEAM="$TEAM_A" -- --identity invalid
assert_fails "requested SHA-1 is not a valid" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_A" MOCK_TEAM="$TEAM_A" -- --identity "$IDENTITY_B"

run_build MOCK_IDENTITIES="$IDENTITY_LINE_A" MOCK_TEAM="$TEAM_A" -- --identity "$(
  /usr/bin/tr '[:upper:]' '[:lower:]' <<< "$IDENTITY_A"
)" >/dev/null
[[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] || fail "successful build did not write Local.xcconfig"
[[ "$(/bin/cat "$BUILDER_COUNT_PATH")" == 1 ]] || fail "successful build did not invoke the fresh builder once"

configured_relative_path="$(/usr/bin/awk -F' = ' '/^SMARTCTL_COMPANION_PATH = / { print $2 }' "$CONFIG_PATH")"
configured_companion_path="${configured_relative_path/'$(SRCROOT)'/$FIXTURE_ROOT}"
[[ -f "$configured_companion_path" && ! -L "$configured_companion_path" ]] \
  || fail "Local.xcconfig does not reference an immutable companion"
configured_digest="$(/usr/bin/awk -F' = ' '/^SMARTCTL_COMPANION_SHA256 = / { print $2 }' "$CONFIG_PATH")"
[[ "$(/usr/bin/shasum -a 256 "$configured_companion_path" | /usr/bin/awk '{ print $1 }')" == "$configured_digest" ]] \
  || fail "Local.xcconfig digest does not match its companion"
config_sha256="$(/usr/bin/shasum -a 256 "$CONFIG_PATH" | /usr/bin/awk '{ print $1 }')"
companion_sha256="$(/usr/bin/shasum -a 256 "$configured_companion_path" | /usr/bin/awk '{ print $1 }')"

assert_fails "" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B" MOCK_CODESIGN_SIGN_FAIL=1
assert_file_unchanged "$CONFIG_PATH" "$config_sha256"
assert_file_unchanged "$configured_companion_path" "$companion_sha256"

assert_fails "" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B" MOCK_CODESIGN_VERIFY_FAIL=1
assert_file_unchanged "$CONFIG_PATH" "$config_sha256"
assert_file_unchanged "$configured_companion_path" "$companion_sha256"

assert_fails "" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B" MOCK_XCODEBUILD_FAIL=1
assert_file_unchanged "$CONFIG_PATH" "$config_sha256"
assert_file_unchanged "$configured_companion_path" "$companion_sha256"

assert_fails "" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B" MOCK_VERIFIER_FAIL=1
assert_file_unchanged "$CONFIG_PATH" "$config_sha256"
assert_file_unchanged "$configured_companion_path" "$companion_sha256"

assert_fails "" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B" MOCK_BUILDER_FAIL=1
assert_file_unchanged "$CONFIG_PATH" "$config_sha256"
assert_file_unchanged "$configured_companion_path" "$companion_sha256"

/bin/mkdir "$FIXTURE_ROOT/DerivedData/LocalSMART/.build-local-smart-app.lock"
assert_fails "another local SMART build is running" \
  run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B"
/bin/rmdir "$FIXTURE_ROOT/DerivedData/LocalSMART/.build-local-smart-app.lock"
assert_file_unchanged "$CONFIG_PATH" "$config_sha256"
assert_file_unchanged "$configured_companion_path" "$companion_sha256"

run_build MOCK_IDENTITIES="$IDENTITY_LINE_B" MOCK_TEAM="$TEAM_B" >/dev/null
[[ "$(/bin/cat "$BUILDER_COUNT_PATH")" == 6 ]] \
  || fail "every post-identity attempt did not use a fresh isolated build"
[[ -f "$configured_companion_path" ]] \
  || fail "publishing Team B removed the prior immutable Team A companion"
[[ "$(/usr/bin/shasum -a 256 "$CONFIG_PATH" | /usr/bin/awk '{ print $1 }')" != "$config_sha256" ]] \
  || fail "successful Team B build did not switch Local.xcconfig"

/usr/bin/grep -Fq 'SMARTCTL_COMPANION_REQUIRED_FOR_SIGNED_BUILD = YES' "$CONFIG_PATH" \
  || fail "Local.xcconfig does not use explicit signed-build requirement semantics"
if /usr/bin/grep -Fq 'SmartctlCompanion/smartctl' "$REPOSITORY_ROOT/Scripts/build-local-smart-app.sh"; then
  fail "production script still references the mutable legacy companion path"
fi
if /usr/bin/grep -Fq '.builder-sha256' "$REPOSITORY_ROOT/Scripts/build-local-smart-app.sh"; then
  fail "production script still trusts an unsigned build cache stamp"
fi
if /usr/bin/grep -Fq '${PLIST_BUDDY' "$REPOSITORY_ROOT/Scripts/verify/code-signing.sh"; then
  fail "signing verifier still accepts an inherited PlistBuddy executable"
fi
/usr/bin/grep -Fq 'helper_architectures="$(/usr/bin/lipo -archs "$HELPER_PATH")"' \
  "$REPOSITORY_ROOT/Scripts/verify/code-signing.sh" \
  || fail "signing verifier does not inspect helper architectures"
/usr/bin/grep -Fq 'for architecture in $helper_architectures' \
  "$REPOSITORY_ROOT/Scripts/verify/code-signing.sh" \
  || fail "signing verifier does not inspect every helper architecture"

echo "Local SMART build regression tests passed."
