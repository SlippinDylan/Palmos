#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH PLIST_BUDDY

readonly APP_PATH="${1:?Usage: create-dmg.sh <app-path> <output-dmg-path> [volume-name]}"
readonly OUTPUT_DMG="${2:?Usage: create-dmg.sh <app-path> <output-dmg-path> [volume-name]}"

# Derive volume name from app bundle name, or use explicit third argument.
if [[ -n "${3:-}" ]]; then
  VOLUME_NAME="$3"
else
  VOLUME_NAME="$(/usr/bin/basename "$APP_PATH" .app)"
fi

readonly VOLUME_NAME
readonly WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}"/palmos-dmg.XXXXXX)"
readonly BACKGROUND_IMAGE="$WORK_DIR/background.png"
readonly RAW_DMG="$WORK_DIR/palmos-temp.dmg"

work_created=false
dmg_attached=false
actual_mount_point=""

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

fail() {
  echo "DMG creation failed: $*" >&2
  exit 1
}

cleanup() {
  # Force-detach DMG if still attached.
  if [[ "$dmg_attached" == true && -n "$actual_mount_point" && -d "$actual_mount_point" ]]; then
    /usr/bin/hdiutil detach "$actual_mount_point" -force 2>/dev/null || true
  fi
  # Remove work directory.
  if [[ "$work_created" == true && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      "${TMPDIR:-/tmp}"/palmos-dmg.*) /bin/rm -rf -- "$WORK_DIR" ;;
    esac
  fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

if [[ ! -d "$APP_PATH" ]]; then
  fail "App bundle not found at $APP_PATH"
fi

if [[ ! -d "$APP_PATH/Contents/MacOS" ]]; then
  fail "$APP_PATH does not appear to be a valid .app bundle (missing Contents/MacOS)"
fi

work_created=true

# ---------------------------------------------------------------------------
# 1. Generate DMG background image (Python stdlib only — no external deps)
# ---------------------------------------------------------------------------

echo "==> Generating DMG background"

/usr/bin/python3 - "$BACKGROUND_IMAGE" <<'PYEOF'
import struct, zlib, sys

out = sys.argv[1]
W, H = 600, 400
BG = (248, 248, 248)
ARROW_COLOR = (120, 120, 120)

def make_pixel(r, g, b, a=255):
    return struct.pack('BBBB', r, g, b, a)

rows = []
for y in range(H):
    row = bytearray()
    for x in range(W):
        r, g, b, a = BG[0], BG[1], BG[2], 255

        cx, cy = W // 2, H // 2
        shaft_top = cy - 14
        shaft_bot = cy + 14
        shaft_left = cx - 90
        shaft_right = cx + 60

        if shaft_left <= x <= shaft_right and shaft_top <= y <= shaft_bot:
            r, g, b = ARROW_COLOR

        head_tip_x = cx + 100
        head_base_x = cx + 55
        head_half_h = 38

        if head_base_x <= x <= head_tip_x:
            t = (x - head_base_x) / (head_tip_x - head_base_x)
            half_height = int(head_half_h * (1.0 - t))
            upper_edge = cy - half_height
            lower_edge = cy + half_height
            if upper_edge <= y <= lower_edge:
                r, g, b = ARROW_COLOR

        circle_cx = shaft_left
        circle_cy = cy
        circle_r = 18
        dx_c = x - circle_cx
        dy_c = y - circle_cy
        if dx_c * dx_c + dy_c * dy_c <= circle_r * circle_r:
            r, g, b = ARROW_COLOR
            if dx_c < 0:
                r, g, b = max(r - 30, 0), max(g - 30, 0), max(b - 30, 0)

        row += make_pixel(r, g, b, a)
    rows.append(bytes(row))

def make_chunk(chunk_type, data):
    c = chunk_type + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

signature = b'\x89PNG\r\n\x1a\n'
ihdr = make_chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))

filtered = b''
for row in rows:
    filtered += b'\x00' + row
idat = make_chunk(b'IDAT', zlib.compress(filtered))
iend = make_chunk(b'IEND', b'')

with open(out, 'wb') as f:
    f.write(signature + ihdr + idat + iend)

print(f"    Background written to {out}  ({W}x{H})")
PYEOF

# ---------------------------------------------------------------------------
# 2. Estimate DMG size from the .app bundle
# ---------------------------------------------------------------------------

echo "==> Calculating DMG size"

# Get the app bundle size (in KB) and add generous overhead for HFS+ metadata
# and the Applications symlink.
APP_SIZE_KB="$(
  /usr/bin/du -sk "$APP_PATH" \
    | /usr/bin/awk '{ print $1 }'
)"
# DMG size = app size + 50% overhead + 20 MB for background, .DS_Store, HFS+ structures.
DMG_SIZE_MB="$(( (APP_SIZE_KB + APP_SIZE_KB / 2) / 1024 + 20 ))"
# Minimum 50 MB, maximum clamped by hdiutil at creation time.
if [[ "$DMG_SIZE_MB" -lt 50 ]]; then
  DMG_SIZE_MB=50
fi

echo "    App size: $(( APP_SIZE_KB / 1024 )) MB  →  DMG size: ${DMG_SIZE_MB} MB"

# ---------------------------------------------------------------------------
# 3. Create empty read/write DMG (no -srcfolder — we copy files manually)
# ---------------------------------------------------------------------------

echo "==> Creating empty DMG image"

# Omit -format when -srcfolder is not used — hdiutil creates a writable
# GPT-partitioned image by default when -size is specified.
/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -size "${DMG_SIZE_MB}M" \
  -quiet \
  "$RAW_DMG" \
  || fail "hdiutil create failed"

# ---------------------------------------------------------------------------
# 4. Attach the DMG
# ---------------------------------------------------------------------------

echo "==> Attaching DMG"

# Find a free mount point (handle name collisions from prior failed runs).
mount_point="/Volumes/$VOLUME_NAME"
counter=1
while /usr/bin/hdiutil info 2>/dev/null | /usr/bin/grep -qF "$mount_point"; do
  mount_point="/Volumes/$VOLUME_NAME $counter"
  counter=$((counter + 1))
done

ATTACH_OUTPUT="$(
  /usr/bin/hdiutil attach "$RAW_DMG" \
    -mountpoint "$mount_point" \
    -nobrowse \
    -noautoopen \
    2>&1
)" || fail "hdiutil attach failed: $ATTACH_OUTPUT"

# Parse the device and actual mount point from hdiutil output.
# Output format:
#   /dev/disk4              Apple_partition_scheme
#   /dev/disk4s1            Apple_partition_map
#   /dev/disk4s2            Apple_HFS                       /Volumes/Palmos
DEVICE="$(echo "$ATTACH_OUTPUT" | /usr/bin/awk '/Apple_HFS/ { print $1 }')"
if [[ -z "$DEVICE" ]]; then
  fail "Could not determine device from attach output: $ATTACH_OUTPUT"
fi

# Extract the actual mount point (last field on the Apple_HFS line).
actual_mount_point="$(echo "$ATTACH_OUTPUT" | /usr/bin/awk '/Apple_HFS/ { for (i=3;i<=NF;i++) printf "%s%s", $i, (i==NF?"\n":" ") }' | /usr/bin/sed 's/ *$//')"
if [[ -z "$actual_mount_point" || ! -d "$actual_mount_point" ]]; then
  fail "Could not locate mount point — attach output: $ATTACH_OUTPUT"
fi
dmg_attached=true

echo "    Attached at $actual_mount_point  (device $DEVICE)"

# ---------------------------------------------------------------------------
# 5. Copy app bundle and create Applications symlink
# ---------------------------------------------------------------------------

echo "==> Copying app bundle into DMG"

# ditto preserves resource forks, symlinks, Finder info, and extended attributes.
/usr/bin/ditto "$APP_PATH" "$actual_mount_point/$(/usr/bin/basename "$APP_PATH")" \
  || fail "ditto copy of app bundle failed"

echo "    Creating /Applications symlink"
/bin/ln -s /Applications "$actual_mount_point/Applications"

# Copy background image into a hidden folder on the volume.
echo "    Copying background image"
/bin/mkdir -p "$actual_mount_point/.background"
/bin/cp "$BACKGROUND_IMAGE" "$actual_mount_point/.background/background.png"

# Set volume icon from the app's icon.
APP_ICON_TARGET="$actual_mount_point/.VolumeIcon.icns"
APP_BUNDLE_ICON="$actual_mount_point/$(/usr/bin/basename "$APP_PATH")/Contents/Resources/AppIcon.icns"
if [[ -f "$APP_BUNDLE_ICON" ]]; then
  /bin/cp "$APP_BUNDLE_ICON" "$APP_ICON_TARGET" 2>/dev/null || true
  /usr/bin/SetFile -a C "$actual_mount_point" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 6. Configure Finder window layout (best-effort in CI)
# ---------------------------------------------------------------------------

echo "    Configuring Finder window layout"

/usr/bin/osascript - "$actual_mount_point" "$VOLUME_NAME" <<'OSAEOF' 2>/dev/null || \
  echo "    Note: AppleScript not available (headless env) — DMG is still functional"
on run argv
  set mountPoint to item 1 of argv
  set volumeName to item 2 of argv

  tell application "Finder"
    set targetVolume to disk volumeName
    open mountPoint
    delay 0.5

    set targetWindow to first window whose target is targetVolume

    tell targetWindow
      set toolbar visible to false
      set statusbar visible to false
      set sidebar width to 0
      set current view to icon view
      set bounds to {200, 200, 800, 600}
    end tell

    tell icon view options of targetWindow
      set arrangement to not arranged
      set icon size to 96
      set shows item info to false
      set shows icon preview to true
      set background picture to file ".background:background.png" of targetVolume
    end tell

    set appName to name of (first file of targetVolume whose name ends with ".app")
    set position of item appName of targetWindow to {160, 180}
    set position of item "Applications" of targetWindow to {440, 180}

    update targetWindow with reload
    close targetWindow
    delay 0.3
    open mountPoint

    set reopenedWindow to first window whose target is targetVolume
    tell reopenedWindow
      set toolbar visible to false
      set statusbar visible to false
      set current view to icon view
    end tell
    tell icon view options of reopenedWindow
      set arrangement to not arranged
      set icon size to 96
      set background picture to file ".background:background.png" of targetVolume
    end tell
    set position of item appName of reopenedWindow to {160, 180}
    set position of item "Applications" of reopenedWindow to {440, 180}
    update reopenedWindow with reload
    close reopenedWindow
  end tell
end run
OSAEOF

# ---------------------------------------------------------------------------
# 7. Detach and convert to compressed read-only DMG
# ---------------------------------------------------------------------------

echo "==> Detaching and finalizing DMG"

/usr/bin/hdiutil detach "$actual_mount_point" -force || fail "Failed to detach DMG"
dmg_attached=false

echo "    Converting to compressed read-only DMG (UDZO)"
/usr/bin/hdiutil convert "$RAW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" \
  || fail "hdiutil convert failed"

# Clean up work directory explicitly so cleanup() doesn't re-run on stale state.
/bin/rm -rf -- "$WORK_DIR"
work_created=false

echo "==> DMG created at $OUTPUT_DMG"

