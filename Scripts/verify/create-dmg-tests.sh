#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH

readonly REPOSITORY_ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly WORK_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/palmos-dmg-tests.XXXXXX")"
readonly APP_PATH="$WORK_DIRECTORY/Palmos.app"
readonly DMG_PATH="$WORK_DIRECTORY/Palmos-test.dmg"
readonly MOUNT_POINT="$WORK_DIRECTORY/mounted"
dmg_attached=false

cleanup() {
  if [[ "$dmg_attached" == true ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  /bin/chmod -R u+w "$WORK_DIRECTORY" 2>/dev/null || true
  /bin/rm -rf -- "$WORK_DIRECTORY"
}
trap cleanup EXIT

fail() {
  echo "DMG packaging regression failed: $*" >&2
  exit 1
}

/bin/mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$MOUNT_POINT"
/usr/bin/touch "$APP_PATH/Contents/MacOS/Palmos"
/usr/bin/plutil -create xml1 "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string Palmos "$APP_PATH/Contents/Info.plist"
/usr/bin/printf 'fixture icon' > "$APP_PATH/Contents/Resources/Palmos.icns"

"$REPOSITORY_ROOT/Scripts/create-dmg.sh" "$APP_PATH" "$DMG_PATH" "Palmos Test"
[[ -f "$DMG_PATH" ]] || fail "create-dmg.sh did not create the output image"

/usr/bin/hdiutil attach "$DMG_PATH" \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  -quiet
dmg_attached=true

[[ -d "$MOUNT_POINT/Palmos.app" ]] || fail "Palmos.app is missing"
[[ -L "$MOUNT_POINT/Applications" ]] || fail "Applications is not a symlink"
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || fail "Applications symlink has the wrong target"
[[ -s "$MOUNT_POINT/.background/background.png" ]] || fail "DMG background is missing"
[[ -s "$MOUNT_POINT/.DS_Store" ]] || fail "Finder .DS_Store metadata is missing"
[[ -s "$MOUNT_POINT/.VolumeIcon.icns" ]] || fail "DMG volume icon is missing"
cmp "$APP_PATH/Contents/Resources/Palmos.icns" "$MOUNT_POINT/.VolumeIcon.icns" \
  || fail "DMG volume icon does not match the app icon"
[[ ! -e "$MOUNT_POINT/vendor" ]] || fail "build-only Python dependencies leaked into the DMG"

PYTHONPATH="$REPOSITORY_ROOT/Scripts/vendor" /usr/bin/python3 \
  - "$MOUNT_POINT/.DS_Store" <<'PYEOF'
import sys

from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as store:
    assert store["Palmos.app"]["Iloc"] == (160, 180)
    assert store["Applications"]["Iloc"] == (440, 180)
    assert store["."]["icvl"] == (b"type", b"icnv")
    icon_view = store["."]["icvp"]
    assert icon_view["backgroundType"] == 2
    assert icon_view["iconSize"] == 96.0
    assert icon_view["arrangeBy"] == "none"
    assert icon_view["backgroundImageAlias"]
    window = store["."]["bwsp"]
    assert window["WindowBounds"] == "{{200, 200}, {600, 400}}"
    assert window["ShowToolbar"] is False
    assert window["ShowSidebar"] is False
PYEOF

/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
dmg_attached=false

echo "DMG packaging regression checks passed"
