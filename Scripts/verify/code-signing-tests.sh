#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH

readonly REPOSITORY_ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/palmos-signing-tests.XXXXXX")"
case "$work_directory" in
  "${TMPDIR:-/tmp}"/palmos-signing-tests.*) ;;
  *) echo "Unexpected test directory: $work_directory" >&2; exit 1 ;;
esac
trap '/bin/rm -rf -- "$work_directory"' EXIT

fail() {
  echo "Code-signing verifier regression failed: $*" >&2
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

readonly FIXTURE_ROOT="$work_directory/Signing Fixture"
readonly MOCK_TOOLS="$FIXTURE_ROOT/mock tools"
readonly APP_PATH="$FIXTURE_ROOT/Palmos.app"
readonly HELPER_PATH="$APP_PATH/Contents/Library/LaunchServices/com.palmos.smartservice"
readonly COMPANION_PATH="$APP_PATH/Contents/Library/Helpers/com.palmos.smartservice.smartctl"
readonly SOURCE_ARCHIVE_PATH="$APP_PATH/Contents/Resources/ThirdPartySources/smartmontools-7.5.tar.gz"
readonly VERIFIER="$FIXTURE_ROOT/code-signing.sh"
readonly TEAM_ID="TESTTEAM12"

/bin/mkdir -p \
  "$MOCK_TOOLS" \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Library/LaunchServices" \
  "$APP_PATH/Contents/Library/Helpers" \
  "$APP_PATH/Contents/Resources/ThirdPartySources"
/usr/bin/touch "$APP_PATH/Contents/MacOS/Palmos" "$HELPER_PATH" "$APP_PATH/Contents/Info.plist"
/bin/cat > "$COMPANION_PATH" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  echo "smartctl 7.5 mock"
fi
EOF
/bin/chmod 0755 "$COMPANION_PATH"
/bin/cp "$REPOSITORY_ROOT/Shared/Licensing/smartmontools-COPYING.txt" \
  "$APP_PATH/Contents/Resources/smartmontools-COPYING.txt"
/bin/cp "$REPOSITORY_ROOT/Shared/Licensing/MenuBarExtraAccess-LICENSE.txt" \
  "$APP_PATH/Contents/Resources/MenuBarExtraAccess-LICENSE.txt"
/bin/cp "$REPOSITORY_ROOT/LICENSE" \
  "$APP_PATH/Contents/Resources/LICENSE"
/usr/bin/printf 'mock smartmontools 7.5 source archive\n' > "$SOURCE_ARCHIVE_PATH"
readonly SOURCE_ARCHIVE_SHA256="$(/usr/bin/shasum -a 256 "$SOURCE_ARCHIVE_PATH" | /usr/bin/awk '{ print $1 }')"
readonly COMPANION_SHA256="$(/usr/bin/shasum -a 256 "$COMPANION_PATH" | /usr/bin/awk '{ print $1 }')"

/usr/bin/sed \
  -e "s#/usr/bin/codesign#\"$MOCK_TOOLS/codesign\"#g" \
  -e "s#/usr/bin/lipo#\"$MOCK_TOOLS/lipo\"#g" \
  -e "s#/usr/bin/otool#\"$MOCK_TOOLS/otool\"#g" \
  -e "s#/usr/bin/vtool#\"$MOCK_TOOLS/vtool\"#g" \
  -e "s#/usr/bin/strings#\"$MOCK_TOOLS/strings\"#g" \
  -e "s#/usr/bin/stat#\"$MOCK_TOOLS/stat\"#g" \
  -e "s#/usr/bin/xxd#\"$MOCK_TOOLS/xxd\"#g" \
  -e "s#/usr/bin/plutil#\"$MOCK_TOOLS/plutil\"#g" \
  -e "s#/usr/bin/csreq#\"$MOCK_TOOLS/csreq\"#g" \
  -e "s#/usr/libexec/PlistBuddy#\"$MOCK_TOOLS/PlistBuddy\"#g" \
  -e "s#690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e#$SOURCE_ARCHIVE_SHA256#g" \
  "$REPOSITORY_ROOT/Scripts/verify/code-signing.sh" > "$VERIFIER"

/bin/cat > "$MOCK_TOOLS/codesign" <<'EOF'
#!/bin/bash
set -euo pipefail
path=""
for argument in "$@"; do
  path="$argument"
done
case " $* " in
  *" -d "*)
    case "$path" in
      *.app) identifier="com.palmos.app" ;;
      */LaunchServices/*) identifier="com.palmos.smartservice" ;;
      */Helpers/*) identifier="com.palmos.smartservice.smartctl" ;;
      *) exit 71 ;;
    esac
    printf 'Identifier=%s\n' "$identifier" >&2
    printf 'TeamIdentifier=%s\n' "${MOCK_TEAM_ID:?}" >&2
    ;;
  *" --verify "*) exit 0 ;;
  *) exit 72 ;;
esac
EOF

/bin/cat > "$MOCK_TOOLS/lipo" <<'EOF'
#!/bin/bash
path=""
for argument in "$@"; do
  path="$argument"
done
case "$path" in
  */MacOS/Palmos) printf '%s\n' "${MOCK_APP_ARCHS:-arm64}" ;;
  */LaunchServices/*) printf '%s\n' "${MOCK_HELPER_ARCHS:-arm64}" ;;
  */Helpers/*) printf '%s\n' "${MOCK_COMPANION_ARCHS:-arm64}" ;;
  *) exit 73 ;;
esac
EOF

/bin/cat > "$MOCK_TOOLS/otool" <<'EOF'
#!/bin/bash
case " $* " in
  *" -L "*) exit 0 ;;
  *" __info_plist "*) printf '00000000 00\n' ;;
  *) exit 74 ;;
esac
EOF

/bin/cat > "$MOCK_TOOLS/vtool" <<'EOF'
#!/bin/bash
path="${@: -1}"
case "$path" in
  */MacOS/Palmos) minos="${MOCK_APP_MINOS:-26.0}" ;;
  */LaunchServices/*) minos="${MOCK_HELPER_MINOS:-26.0}" ;;
  */Helpers/*) minos="${MOCK_COMPANION_MINOS:-26.0}" ;;
  *) exit 76 ;;
esac
printf '    minos %s\n' "$minos"
EOF

/bin/cat > "$MOCK_TOOLS/strings" <<'EOF'
#!/bin/bash
exit 0
EOF

/bin/cat > "$MOCK_TOOLS/stat" <<'EOF'
#!/bin/bash
printf '1024\n'
EOF

/bin/cat > "$MOCK_TOOLS/xxd" <<'EOF'
#!/bin/bash
/bin/cat
EOF

/bin/cat > "$MOCK_TOOLS/plutil" <<'EOF'
#!/bin/bash
exit 0
EOF

/bin/cat > "$MOCK_TOOLS/csreq" <<'EOF'
#!/bin/bash
exit 0
EOF

/bin/cat > "$MOCK_TOOLS/PlistBuddy" <<'EOF'
#!/bin/bash
set -euo pipefail
command=""
path=""
while (($# > 0)); do
  case "$1" in
    -c) command="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
case "$command" in
  "Print :SMPrivilegedExecutables:"*)
    printf 'identifier "com.palmos.smartservice" and anchor apple generic\n'
    ;;
  "Print :PalmosSmartctlCompanionRequirement")
    printf 'identifier "com.palmos.smartservice.smartctl" and anchor apple generic\n'
    ;;
  "Print :PalmosSmartctlCompanionSHA256")
    printf '%s\n' "${MOCK_COMPANION_SHA256:?}"
    ;;
  "Print :SMAuthorizedClients:0")
    printf 'identifier "com.palmos.app" and anchor apple generic\n'
    ;;
  "Print :SMAuthorizedClients:"*) exit 1 ;;
  *) exit 75 ;;
esac
EOF

/bin/chmod 0755 "$VERIFIER" "$MOCK_TOOLS"/*

run_verifier() {
  /usr/bin/env \
    MOCK_TEAM_ID="$TEAM_ID" \
    MOCK_COMPANION_SHA256="$COMPANION_SHA256" \
    "$@" \
    "$VERIFIER" "$APP_PATH" "$TEAM_ID"
}

run_verifier >/dev/null
source_archive_backup="$work_directory/smartmontools-7.5.tar.gz"
/bin/mv "$SOURCE_ARCHIVE_PATH" "$source_archive_backup"
assert_fails "bundled smartmontools source archive not found" run_verifier
/bin/mv "$source_archive_backup" "$SOURCE_ARCHIVE_PATH"
/bin/cp "$SOURCE_ARCHIVE_PATH" "$source_archive_backup"
/usr/bin/printf 'tampered\n' >> "$SOURCE_ARCHIVE_PATH"
assert_fails "bundled smartmontools source archive SHA-256" run_verifier
/bin/mv "$source_archive_backup" "$SOURCE_ARCHIVE_PATH"
assert_fails "app architectures 'arm64' do not match helper architectures 'x86_64'" \
  run_verifier MOCK_HELPER_ARCHS=x86_64
assert_fails "app architectures 'arm64' do not match companion architectures 'x86_64'" \
  run_verifier MOCK_COMPANION_ARCHS=x86_64
assert_fails "release architecture is 'arm64 x86_64', expected 'arm64'" \
  run_verifier \
    MOCK_APP_ARCHS='arm64 x86_64' \
    MOCK_HELPER_ARCHS='arm64 x86_64' \
    MOCK_COMPANION_ARCHS='arm64 x86_64'
assert_fails "app minimum system is '15.0', expected '26.0'" \
  run_verifier MOCK_APP_MINOS=15.0
assert_fails "helper minimum system is '15.0', expected '26.0'" \
  run_verifier MOCK_HELPER_MINOS=15.0
assert_fails "smartctl companion minimum system is '15.0', expected '26.0'" \
  run_verifier MOCK_COMPANION_MINOS=15.0

marker_path="$work_directory/inherited-plist-buddy-ran"
/usr/bin/env \
  PLIST_BUDDY="$marker_path" \
  MOCK_TEAM_ID="$TEAM_ID" \
  MOCK_COMPANION_SHA256="$COMPANION_SHA256" \
  "$VERIFIER" "$APP_PATH" "$TEAM_ID" >/dev/null
[[ ! -e "$marker_path" ]] || fail "verifier executed inherited PLIST_BUDDY"

echo "Code-signing verifier regression tests passed."
