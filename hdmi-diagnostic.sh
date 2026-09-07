#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
state_dir="$project_dir/.hdmi-diagnostics"
active_file="$state_dir/active"
container_name="ubuntu26-gnome-hdmi"
capture_seconds=600

if (( EUID != 0 )); then
  echo "Run with sudo: sudo ./hdmi-diagnostic.sh {start|snapshot|stop|status}" >&2
  exit 2
fi

mkdir -p "$state_dir"

connector_status() {
  local status_file
  for status_file in /sys/class/drm/card0-*/status; do
    [[ -e "$status_file" ]] || continue
    printf '%s=' "${status_file%/status}"
    cat "$status_file"
  done
}

write_snapshot() {
  local output_file="$1"
  {
    date -Ins
    uname -a
    printf 'cmdline: '
    cat /proc/cmdline
    printf 'sriov_numvfs: '
    cat /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs 2>/dev/null || true
    connector_status
    echo
    docker ps -a --filter "name=^/${container_name}$"
    docker inspect "$container_name" 2>/dev/null || true
    echo
    fuser -v /dev/dri/card* /dev/dri/renderD* 2>&1 || true
    echo
    ps -eo pid,ppid,stat,wchan:48,comm,args
    echo
    while read -r pid stat; do
      [[ "$stat" == D* ]] || continue
      echo "--- blocked task pid=$pid ---"
      cat "/proc/$pid/stack" 2>/dev/null || true
    done < <(ps -eo pid=,stat=)
    echo
    dmesg -T | tail -n 500
  } >"$output_file" 2>&1
  sync
}

read_active() {
  [[ -f "$active_file" ]] || return 1
  active_boot_id="$(sed -n '1p' "$active_file")"
  active_output_dir="$(sed -n '2p' "$active_file")"
  active_pids="$(sed -n '3p' "$active_file")"
}

case "${1:-}" in
  start)
    if read_active && [[ "$active_boot_id" == "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
      for worker_pid in $active_pids; do
        if kill -0 "$worker_pid" 2>/dev/null; then
          echo "Capture is already active: $active_output_dir" >&2
          exit 3
        fi
      done
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    output_dir="$state_dir/$stamp"
    mkdir -p "$output_dir"
    write_snapshot "$output_dir/before.txt"

    timeout "$capture_seconds" stdbuf -oL dmesg -wT \
      >"$output_dir/kernel-follow.log" 2>&1 &
    kernel_pid=$!

    timeout "$capture_seconds" stdbuf -oL docker exec "$container_name" \
      journalctl -f -o short-monotonic \
      >"$output_dir/container-follow.log" 2>&1 &
    container_pid=$!

    (
      end_time=$((SECONDS + capture_seconds))
      while (( SECONDS < end_time )); do
        date -Ins
        connector_status
        ps -eo pid,stat,wchan:48,comm | \
          grep -E 'gnome-shell|systemd-logind|dockerd|containerd|^[[:space:]]*[0-9]+[[:space:]]+D' || true
        sleep 1
      done
    ) >"$output_dir/state-follow.log" 2>&1 &
    state_pid=$!

    (
      end_time=$((SECONDS + capture_seconds))
      while (( SECONDS < end_time )); do
        sleep 5
        sync
      done
    ) >/dev/null 2>&1 &
    sync_pid=$!

    printf '%s\n%s\n%s %s %s %s\n' \
      "$(cat /proc/sys/kernel/random/boot_id)" "$output_dir" \
      "$kernel_pid" "$container_pid" "$state_pid" "$sync_pid" >"$active_file"
    ln -sfn "$output_dir" "$state_dir/latest"
    echo "Capturing for at most ${capture_seconds}s: $output_dir"
    ;;

  snapshot)
    # Ask the kernel to print blocked tasks before collecting its ring buffer.
    if [[ -w /proc/sysrq-trigger ]]; then
      echo w >/proc/sysrq-trigger 2>/dev/null || true
      sleep 1
    fi
    if read_active; then
      output_dir="$active_output_dir"
    else
      stamp="$(date +%Y%m%d-%H%M%S)"
      output_dir="$state_dir/$stamp"
      mkdir -p "$output_dir"
      ln -sfn "$output_dir" "$state_dir/latest"
    fi
    snapshot_file="$output_dir/snapshot-$(date +%H%M%S).txt"
    write_snapshot "$snapshot_file"
    echo "Snapshot written: $snapshot_file"
    ;;

  stop)
    if ! read_active; then
      echo "No active capture."
      exit 0
    fi
    if [[ "$active_boot_id" == "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
      for worker_pid in $active_pids; do
        kill "$worker_pid" 2>/dev/null || true
      done
    fi
    write_snapshot "$active_output_dir/after.txt"
    mv "$active_file" "$active_output_dir/controller-state.txt"
    echo "Capture stopped: $active_output_dir"
    ;;

  status)
    if ! read_active; then
      echo "No active capture."
      exit 0
    fi
    echo "Output: $active_output_dir"
    for worker_pid in $active_pids; do
      if kill -0 "$worker_pid" 2>/dev/null; then
        echo "running pid=$worker_pid"
      else
        echo "finished pid=$worker_pid"
      fi
    done
    ;;

  *)
    echo "Usage: sudo ./hdmi-diagnostic.sh {start|snapshot|stop|status}" >&2
    exit 2
    ;;
esac
