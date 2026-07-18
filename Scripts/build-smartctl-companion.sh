#!/bin/bash

set -euo pipefail

readonly SMARTMONTOOLS_VERSION="7.5"
readonly SMARTMONTOOLS_ARCHIVE="smartmontools-${SMARTMONTOOLS_VERSION}.tar.gz"
readonly SMARTMONTOOLS_URL="https://downloads.sourceforge.net/project/smartmontools/smartmontools/${SMARTMONTOOLS_VERSION}/${SMARTMONTOOLS_ARCHIVE}"
readonly SMARTMONTOOLS_SHA256="690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e"
readonly OUTPUT_DIRECTORY="${1:?Usage: build-smartctl-companion.sh <output-directory>}"
readonly SOURCE_ARCHIVE_OVERRIDE="${SMARTMONTOOLS_SOURCE_ARCHIVE:-}"

fail() {
  echo "smartctl companion build failed: $*" >&2
  exit 1
}

verify_archive() {
  local archive_path="$1"
  local actual_sha256

  actual_sha256="$(shasum -a 256 "$archive_path" | awk '{ print $1 }')"
  [[ "$actual_sha256" == "$SMARTMONTOOLS_SHA256" ]] \
    || fail "source archive SHA-256 is $actual_sha256, expected $SMARTMONTOOLS_SHA256"
}

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/drivepulse-smartctl.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

archive_path="$work_directory/$SMARTMONTOOLS_ARCHIVE"
if [[ -n "$SOURCE_ARCHIVE_OVERRIDE" ]]; then
  [[ -f "$SOURCE_ARCHIVE_OVERRIDE" ]] \
    || fail "SMARTMONTOOLS_SOURCE_ARCHIVE does not exist at $SOURCE_ARCHIVE_OVERRIDE"
  cp "$SOURCE_ARCHIVE_OVERRIDE" "$archive_path"
else
  curl \
    --fail \
    --location \
    --proto '=https' \
    --silent \
    --show-error \
    --output "$archive_path" \
    "$SMARTMONTOOLS_URL"
fi
verify_archive "$archive_path"

source_directory="$work_directory/source"
mkdir -p "$source_directory"
tar -xzf "$archive_path" -C "$source_directory" --strip-components=1
[[ -f "$source_directory/COPYING" ]] || fail "upstream COPYING file is missing"

readonly DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
readonly BUILD_ARCHITECTURES="${SMARTCTL_BUILD_ARCHS:-arm64 x86_64}"
readonly SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

build_slices=()
for architecture in $BUILD_ARCHITECTURES; do
  case "$architecture" in
    arm64) configure_host="aarch64-apple-darwin" ;;
    x86_64) configure_host="x86_64-apple-darwin" ;;
    *) fail "unsupported architecture '$architecture'" ;;
  esac

  build_directory="$work_directory/build-$architecture"
  mkdir -p "$build_directory"
  cd "$build_directory"

  common_flags="-arch $architecture -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK_PATH"
  env \
    CC="$(xcrun --find clang)" \
    CXX="$(xcrun --find clang++)" \
    CFLAGS="-O2 -g0 $common_flags" \
    CXXFLAGS="-O2 -g0 $common_flags" \
    LDFLAGS="$common_flags" \
    "$source_directory/configure" \
      --host="$configure_host" \
      --prefix=/Library/PrivilegedHelperTools/DrivePulseSmartctl \
      --with-drivedbdir=no \
      --without-gnupg \
      --without-libcap-ng \
      --without-libsystemd \
      --without-selinux

  make -j"$(sysctl -n hw.logicalcpu)" smartctl
  build_slices+=("$build_directory/smartctl")
done

mkdir -p "$OUTPUT_DIRECTORY"
lipo -create "${build_slices[@]}" -output "$OUTPUT_DIRECTORY/smartctl"
chmod 0755 "$OUTPUT_DIRECTORY/smartctl"
install -m 0644 "$source_directory/COPYING" "$OUTPUT_DIRECTORY/smartmontools-COPYING.txt"
install -m 0644 "$archive_path" "$OUTPUT_DIRECTORY/$SMARTMONTOOLS_ARCHIVE"

actual_architecture="$(lipo -archs "$OUTPUT_DIRECTORY/smartctl")"
for architecture in $BUILD_ARCHITECTURES; do
  case " $actual_architecture " in
    *" $architecture "*) ;;
    *) fail "built smartctl architectures '$actual_architecture' omit '$architecture'" ;;
  esac
done

"$OUTPUT_DIRECTORY/smartctl" --version | head -n 1
echo "Built smartctl companion from smartmontools $SMARTMONTOOLS_VERSION."
