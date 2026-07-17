#!/bin/bash
set -euo pipefail
umask 077

readonly STATE_DIR="${TMPDIR:-/tmp}/drivepulse-safe-eject-fixture-${UID}"
readonly RISK_FLAG="--i-understand-this-volume-is-disposable"

usage() {
  cat <<'EOF'
DrivePulse safe-eject disposable-media fixture

Read-only inspection:
  safe-eject-fixture.sh check --device diskN

Create holders (DISPOSABLE TEST MEDIA ONLY):
  safe-eject-fixture.sh open-file-holder --device diskN --volume /Volumes/Test --i-understand-this-volume-is-disposable
  safe-eject-fixture.sh working-directory-holder --device diskN --volume /Volumes/Test --i-understand-this-volume-is-disposable
  safe-eject-fixture.sh device-node-holder --device diskN --volume /Volumes/Test --i-understand-this-volume-is-disposable
  safe-eject-fixture.sh release-holders --device diskN

The script never unmounts, ejects, force-unmounts, or terminates unrelated processes.
With no subcommand it prints this help and performs no system changes.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  usage
  exit 0
fi
shift

device=""
volume=""
risk_acknowledged=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || fail "--device requires a value"
      device="$2"
      shift 2
      ;;
    --volume)
      [[ $# -ge 2 ]] || fail "--volume requires a value"
      volume="$2"
      shift 2
      ;;
    "$RISK_FLAG")
      risk_acknowledged=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$device" =~ ^disk[0-9]+$ ]] || fail "--device must be a whole BSD name such as disk4"

check_device() {
  local info
  info="$(/usr/sbin/diskutil info -plist "$device")" || fail "diskutil could not resolve $device"
  local whole internal
  whole="$(/usr/bin/plutil -extract Whole raw -o - - <<<"$info" 2>/dev/null || true)"
  internal="$(/usr/bin/plutil -extract Internal raw -o - - <<<"$info" 2>/dev/null || true)"
  [[ "$whole" == true ]] || fail "$device is not a whole disk"
  [[ "$internal" == false ]] || fail "$device is not an external disk"
  /usr/bin/plutil -p - <<<"$info"
}

validate_disposable_volume() {
  [[ "$risk_acknowledged" == true ]] || fail "holder commands require $RISK_FLAG"
  [[ -n "$volume" ]] || fail "holder commands require --volume /Volumes/<DisposableTestVolume>"
  [[ "$volume" == /Volumes/* && "$volume" != "/Volumes/" ]] || fail "volume must be a mounted path below /Volumes"
  [[ -d "$volume" ]] || fail "$volume is not a mounted directory"

  local volume_info parent_disk
  volume_info="$(/usr/sbin/diskutil info -plist "$volume")" || fail "diskutil could not resolve $volume"
  parent_disk="$(/usr/bin/plutil -extract PartOfWhole raw -o - - <<<"$volume_info" 2>/dev/null || true)"
  [[ "$parent_disk" == "$device" ]] || fail "$volume belongs to ${parent_disk:-an unknown disk}, not $device"

  echo "WARNING: use only disposable media containing no valuable data." >&2
  mkdir -m 700 -p "$STATE_DIR"
}

record_holder() {
  local kind="$1"
  local pid="$2"
  local identity
  identity="$(/bin/ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [[ -z "$identity" ]]; then
    kill "$pid" 2>/dev/null || true
    fail "could not capture holder process identity"
  fi
  printf '%s\n%s\n' "$pid" "$identity" >"$STATE_DIR/${device}-${kind}.pid"
  echo "Started $kind holder with PID $pid"
}

case "$command_name" in
  check)
    check_device
    echo
    echo "Mounted descendants:"
    /usr/sbin/diskutil list "$device"
    ;;
  open-file-holder)
    check_device >/dev/null
    validate_disposable_volume
    holder_file="$volume/.drivepulse-safe-eject-holder"
    : >"$holder_file"
    nohup /usr/bin/perl -e 'open my $holder, "<", $ARGV[0] or die $!; sleep 86400' "$holder_file" >/dev/null 2>&1 &
    record_holder open-file "$!"
    printf '%s\n' "$holder_file" >"$STATE_DIR/${device}-holder-file.path"
    ;;
  working-directory-holder)
    check_device >/dev/null
    validate_disposable_volume
    nohup /usr/bin/perl -e 'chdir $ARGV[0] or die $!; sleep 86400' "$volume" >/dev/null 2>&1 &
    record_holder working-directory "$!"
    ;;
  device-node-holder)
    check_device >/dev/null
    validate_disposable_volume
    node="/dev/r${device}"
    [[ -r "$node" ]] || fail "$node is not readable by the current user"
    nohup /usr/bin/perl -e 'open my $holder, "<", $ARGV[0] or die $!; sleep 86400' "$node" >/dev/null 2>&1 &
    record_holder device-node "$!"
    ;;
  release-holders)
    mkdir -m 700 -p "$STATE_DIR"
    found=false
    for pid_file in "$STATE_DIR/${device}-"*.pid; do
      [[ -e "$pid_file" ]] || continue
      found=true
      pid="$(sed -n '1p' "$pid_file")"
      recorded_identity="$(sed -n '2p' "$pid_file")"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        current_identity="$(/bin/ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
        if [[ -n "$recorded_identity" && "$current_identity" == "$recorded_identity" ]]; then
          kill -TERM "$pid"
          echo "Released holder PID $pid"
          for _ in {1..20}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.05
          done
          if kill -0 "$pid" 2>/dev/null; then
            latest_identity="$(/bin/ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
            if [[ "$latest_identity" == "$recorded_identity" ]]; then
              kill -KILL "$pid" 2>/dev/null || true
            fi
          fi
        else
          echo "Skipped PID $pid because it no longer matches the recorded holder" >&2
        fi
      fi
      rm -f "$pid_file"
    done
    path_file="$STATE_DIR/${device}-holder-file.path"
    if [[ -f "$path_file" ]]; then
      holder_file="$(<"$path_file")"
      [[ "$holder_file" == /Volumes/*/.drivepulse-safe-eject-holder ]] && rm -f "$holder_file"
      rm -f "$path_file"
    fi
    [[ "$found" == true ]] || echo "No recorded holders for $device"
    ;;
  *)
    usage
    fail "unknown subcommand: $command_name"
    ;;
esac
