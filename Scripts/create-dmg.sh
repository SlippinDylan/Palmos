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
readonly STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}"/palmos-dmg.XXXXXX)"
readonly BACKGROUND_DIR="$STAGING_DIR/.background"
readonly BACKGROUND_IMAGE="$BACKGROUND_DIR/background.png"
readonly MOUNT_POINT="/Volumes/$VOLUME_NAME"

staging_created=false
dmg_mounted=false

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

fail() {
  echo "DMG creation failed: $*" >&2
  exit 1
}

cleanup() {
  # Detach DMG if still mounted.
  if [[ "$dmg_mounted" == true ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
  fi
  # Remove staging directory.
  if [[ "$staging_created" == true && -d "$STAGING_DIR" && ! -L "$STAGING_DIR" ]]; then
    case "$STAGING_DIR" in
      "${TMPDIR:-/tmp}"/palmos-dmg.*) /bin/rm -rf -- "$STAGING_DIR" ;;
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

# ---------------------------------------------------------------------------
# 1. Stage the DMG contents
# ---------------------------------------------------------------------------

echo "==> Staging DMG contents in $STAGING_DIR"

/bin/mkdir -p "$BACKGROUND_DIR"
staging_created=true

# Copy the app bundle (preserving resource forks, symlinks, and extended attributes).
echo "    Copying $(/usr/bin/basename "$APP_PATH")"
/bin/cp -R -p "$APP_PATH" "$STAGING_DIR/"

# Create a relative symlink to /Applications so the DMG shows the standard
# drag-to-install target.
echo "    Creating /Applications symlink"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

# ---------------------------------------------------------------------------
# 2. Generate DMG background image (simple arrow, Python stdlib only)
# ---------------------------------------------------------------------------

echo "==> Generating DMG background"

/usr/bin/python3 - "$BACKGROUND_IMAGE" <<'PYEOF'
import struct, zlib, sys, math

out = sys.argv[1]
W, H = 600, 400
BG = (248, 248, 248)       # light gray
ARROW_COLOR = (120, 120, 120)  # medium gray arrow
TEXT_COLOR = (100, 100, 100)

def make_pixel(r, g, b, a=255):
    return struct.pack('BBBB', r, g, b, a)

# Build RGBA pixel data, row by row (top→bottom).
rows = []
for y in range(H):
    row = bytearray()
    for x in range(W):
        r, g, b, a = BG[0], BG[1], BG[2], 255

        # Draw a simple right-pointing arrow in the centre area.
        # Arrow shaft: horizontal rectangle.
        cx, cy = W // 2, H // 2
        shaft_top = cy - 14
        shaft_bot = cy + 14
        shaft_left = cx - 90
        shaft_right = cx + 60

        if shaft_left <= x <= shaft_right and shaft_top <= y <= shaft_bot:
            r, g, b = ARROW_COLOR

        # Arrow head (triangle).
        head_tip_x = cx + 100
        head_base_x = cx + 55
        head_half_h = 38

        # Upper half of the arrow head.
        if head_base_x <= x <= head_tip_x:
            t = (x - head_base_x) / (head_tip_x - head_base_x)  # 0..1
            half_height = int(head_half_h * (1.0 - t))
            upper_edge = cy - half_height
            lower_edge = cy + half_height
            if upper_edge <= y <= lower_edge:
                r, g, b = ARROW_COLOR

        # Rounded start of the arrow (circle on the left side of the shaft).
        circle_cx = shaft_left
        circle_cy = cy
        circle_r = 18
        dx_c = x - circle_cx
        dy_c = y - circle_cy
        if dx_c * dx_c + dy_c * dy_c <= circle_r * circle_r:
            r, g, b = ARROW_COLOR
            # Left half of circle is a bit darker (arrow tail)
            if dx_c < 0:
                r, g, b = max(r - 30, 0), max(g - 30, 0), max(b - 30, 0)

        row += make_pixel(r, g, b, a)
    rows.append(bytes(row))

raw = b''.join(rows)

def make_chunk(chunk_type, data):
    c = chunk_type + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

signature = b'\x89PNG\r\n\x1a\n'
ihdr = make_chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))

# Filter byte 0 (None) before each row, then zlib-compress.
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
# 3. Create the uncompressed DMG
# ---------------------------------------------------------------------------

readonly RAW_DMG="$STAGING_DIR/palmos-temp.dmg"

echo "==> Creating DMG image"

/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size 200M \
  "$RAW_DMG" \
  || fail "hdiutil create failed"

# ---------------------------------------------------------------------------
# 4. Mount the DMG and configure Finder window
# ---------------------------------------------------------------------------

echo "==> Mounting DMG to configure window layout"

# Find an available mount point name (handle name collisions).
mount_point="$MOUNT_POINT"
counter=1
while [[ -d "$mount_point" ]]; do
  mount_point="/Volumes/$VOLUME_NAME $counter"
  counter=$((counter + 1))
done

DEVICE="$(
  /usr/bin/hdiutil attach "$RAW_DMG" \
    -mountpoint "$mount_point" \
    -nobrowse \
    -noautoopen \
    2>&1 | /usr/bin/awk '/Apple_HFS/ { print $1 }' || true
)"

if [[ -z "$DEVICE" ]]; then
  fail "Failed to mount DMG"
fi
dmg_mounted=true

# Copy background image into the mounted volume.
/bin/mkdir -p "$mount_point/.background"
/bin/cp "$BACKGROUND_IMAGE" "$mount_point/.background/background.png"

# Set up Finder window layout via AppleScript.
# This step is best-effort — if the script is running headless (CI without a
# window server) it may fail, which is acceptable; the DMG is still usable.
echo "    Configuring Finder window layout"

/usr/bin/osascript - "$mount_point" "$VOLUME_NAME" <<'OSAEOF' 2>/dev/null || \
  echo "    Note: AppleScript failed (possibly headless) — DMG layout not customized"
on run argv
  set mountPoint to item 1 of argv
  set volumeName to item 2 of argv

  tell application "Finder"
    -- Reveal the mounted volume so we can configure its window.
    set targetVolume to disk volumeName
    open mountPoint

    -- Wait briefly for the window to appear.
    delay 0.5

    set targetWindow to first window whose target is targetVolume

    tell targetWindow
      set toolbar visible to false
      set statusbar visible to false
      set sidebar width to 0
      set current view to icon view
      set bounds to {200, 200, 800, 600}
    end tell

    -- Set view options for the window.
    tell icon view options of targetWindow
      set arrangement to not arranged
      set icon size to 96
      set shows item info to false
      set shows icon preview to true
      set background picture to file ".background:background.png" of targetVolume
    end tell

    -- Position the app icon (left) and Applications symlink (right).
    -- Finder uses a grid with top-left as {0, 0}.
    -- Placing app around {140, 180} and Applications around {420, 180}.
    set appName to name of (first file of targetVolume whose name ends with ".app")
    set position of item appName of targetWindow to {160, 180}
    set position of item "Applications" of targetWindow to {440, 180}

    -- Refresh.
    update targetWindow with reload
    close targetWindow
    delay 0.3
    open mountPoint

    -- Re-apply icon positions after refresh (Finder sometimes resets on open).
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

# Set custom icon for the volume (optional, best-effort).
# Copy the app's icon as the volume icon.
APP_ICON="$mount_point/.VolumeIcon.icns"
APP_BUNDLE_ICON="$mount_point/$(/usr/bin/basename "$APP_PATH")/Contents/Resources/AppIcon.icns"
if [[ -f "$APP_BUNDLE_ICON" ]]; then
  /bin/cp "$APP_BUNDLE_ICON" "$APP_ICON" 2>/dev/null || true
  /usr/bin/SetFile -a C "$mount_point" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 5. Detach and finalize
# ---------------------------------------------------------------------------

echo "==> Detaching and finalizing DMG"

/usr/bin/hdiutil detach "$mount_point" -force || fail "Failed to detach DMG"
dmg_mounted=false

# Convert to compressed read-only DMG (UDZO — zlib-compressed, the standard format).
echo "    Converting to compressed read-only DMG"
/usr/bin/hdiutil convert "$RAW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" \
  || fail "hdiutil convert failed"

# Clean up staging directory explicitly so cleanup() doesn't trip on it.
/bin/rm -rf -- "$STAGING_DIR"
staging_created=false

echo "==> DMG created at $OUTPUT_DMG"
