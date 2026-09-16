#!/bin/bash

set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH PLIST_BUDDY

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

[[ "$(/usr/sbin/sysctl -n hw.optional.arm64)" == 1 ]] \
  || fail "arm64 smartctl builds require Apple Silicon hardware"

verify_archive() {
  local archive_path="$1"
  local actual_sha256

  actual_sha256="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{ print $1 }')"
  [[ "$actual_sha256" == "$SMARTMONTOOLS_SHA256" ]] \
    || fail "source archive SHA-256 is $actual_sha256, expected $SMARTMONTOOLS_SHA256"
}

[[ "$OUTPUT_DIRECTORY" == /* && "$OUTPUT_DIRECTORY" != / ]] \
  || fail "output directory must be an absolute, non-root path"
[[ ! -L "$OUTPUT_DIRECTORY" ]] \
  || fail "refusing symbolic-link output directory at $OUTPUT_DIRECTORY"
if [[ -e "$OUTPUT_DIRECTORY" ]]; then
  [[ -d "$OUTPUT_DIRECTORY" ]] || fail "output path is not a directory: $OUTPUT_DIRECTORY"
  [[ "$(/usr/bin/stat -f%u "$OUTPUT_DIRECTORY")" == "$EUID" ]] \
    || fail "output directory is not owned by the current user"
else
  /bin/mkdir -p -m 0700 "$OUTPUT_DIRECTORY"
fi
/bin/chmod 0700 "$OUTPUT_DIRECTORY"
for output_name in smartctl smartmontools-COPYING.txt "$SMARTMONTOOLS_ARCHIVE"; do
  [[ ! -L "$OUTPUT_DIRECTORY/$output_name" ]] \
    || fail "refusing symbolic-link output file at $OUTPUT_DIRECTORY/$output_name"
done

readonly TEMPORARY_ROOT="${TMPDIR:-/tmp}"
[[ "$TEMPORARY_ROOT" == /* && -d "$TEMPORARY_ROOT" ]] \
  || fail "TMPDIR must name an existing absolute directory"
work_directory="$(/usr/bin/mktemp -d "$TEMPORARY_ROOT/palmos-smartctl.XXXXXX")"
case "$work_directory" in
  "$TEMPORARY_ROOT"/palmos-smartctl.*) ;;
  *) fail "mktemp returned an unexpected path: $work_directory" ;;
esac
[[ -d "$work_directory" && ! -L "$work_directory" ]] \
  || fail "temporary build directory is unsafe: $work_directory"
trap '/bin/rm -rf -- "$work_directory"' EXIT

archive_path="$work_directory/$SMARTMONTOOLS_ARCHIVE"
if [[ -n "$SOURCE_ARCHIVE_OVERRIDE" ]]; then
  [[ -f "$SOURCE_ARCHIVE_OVERRIDE" ]] \
    || fail "SMARTMONTOOLS_SOURCE_ARCHIVE does not exist at $SOURCE_ARCHIVE_OVERRIDE"
  /bin/cp "$SOURCE_ARCHIVE_OVERRIDE" "$archive_path"
else
  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --silent \
    --show-error \
    --output "$archive_path" \
    "$SMARTMONTOOLS_URL"
fi
verify_archive "$archive_path"

source_directory="$work_directory/source"
/bin/mkdir -p "$source_directory"
/usr/bin/tar -xzf "$archive_path" -C "$source_directory" --strip-components=1
[[ -f "$source_directory/COPYING" ]] || fail "upstream COPYING file is missing"

readonly DEPLOYMENT_TARGET="26.0"
readonly BUILD_ARCHITECTURE="arm64"
readonly SDK_PATH="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"

build_directory="$work_directory/build-$BUILD_ARCHITECTURE"
/bin/mkdir -p "$build_directory"
cd "$build_directory"

common_flags="-arch $BUILD_ARCHITECTURE -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK_PATH"
/usr/bin/env \
  CC="$(/usr/bin/xcrun --find clang)" \
  CXX="$(/usr/bin/xcrun --find clang++)" \
  CFLAGS="-O2 -g0 $common_flags" \
  CXXFLAGS="-O2 -g0 $common_flags" \
  LDFLAGS="$common_flags" \
  "$source_directory/configure" \
    --host=aarch64-apple-darwin \
    --prefix=/Library/PrivilegedHelperTools/PalmosSmartctl \
    --with-drivedbdir=no \
    --without-gnupg \
    --without-libcap-ng \
    --without-libsystemd \
    --without-selinux

/usr/bin/make -j"$(/usr/sbin/sysctl -n hw.logicalcpu)" smartctl
/usr/bin/install -m 0755 "$build_directory/smartctl" "$OUTPUT_DIRECTORY/smartctl"
/usr/bin/install -m 0644 "$source_directory/COPYING" "$OUTPUT_DIRECTORY/smartmontools-COPYING.txt"
/usr/bin/install -m 0644 "$archive_path" "$OUTPUT_DIRECTORY/$SMARTMONTOOLS_ARCHIVE"

actual_architecture="$(/usr/bin/lipo -archs "$OUTPUT_DIRECTORY/smartctl")"
[[ "$actual_architecture" == "$BUILD_ARCHITECTURE" ]] \
  || fail "built smartctl architecture is '$actual_architecture', expected '$BUILD_ARCHITECTURE'"

smartctl_version_output="$("$OUTPUT_DIRECTORY/smartctl" --version)"
printf '%s\n' "${smartctl_version_output%%$'\n'*}"
echo "Built smartctl companion from smartmontools $SMARTMONTOOLS_VERSION."
