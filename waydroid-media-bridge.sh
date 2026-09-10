#!/bin/bash
set -euo pipefail

env_file=/run/fnos-desktop.env
[[ -r "$env_file" ]] && source "$env_file"

desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_uid="${DESKTOP_UID:-1000}"
desktop_gid="${DESKTOP_GID:-1000}"
media_source="${WAYDROID_MEDIA_SOURCE:-}"
effective_media_source="$media_source"
media_target="${WAYDROID_MEDIA_TARGET:-Pictures/nas}"
media_mode="${WAYDROID_MEDIA_MODE:-ro}"
scan_interval="${WAYDROID_MEDIA_SCAN_INTERVAL:-1800}"
lxc_path=/var/lib/waydroid/lxc
lxc_name=waydroid

raw_target="/home/$desktop_user/.local/share/waydroid/data/media/0/$media_target"
android_target="/storage/emulated/0/$media_target"
android_source="/data/media/0/$media_target"
declare -A mounted_namespaces=()
bindfs_pid=

validate_config() {
  [[ -n "$media_source" ]] || exit 0
  [[ "$media_source" == /mnt/fnos/* ]] || {
    echo "WAYDROID_MEDIA_SOURCE must be below /mnt/fnos" >&2
    exit 2
  }
  # The desktop-friendly /mnt/fnos tree is itself a bindfs/FUSE view. Building
  # another bindfs on top of it can block service stop during heavy scans.
  # Prefer the corresponding raw host mount and apply ownership exactly once.
  if [[ "$media_source" == /mnt/fnos/* ]]; then
    local raw_candidate="/mnt/fnos-raw/${media_source#/mnt/fnos/}"
    [[ -d "$raw_candidate" ]] && effective_media_source="$raw_candidate"
  fi
  [[ -d "$effective_media_source" ]] || {
    echo "Waydroid media source does not exist: $media_source" >&2
    exit 3
  }
  [[ "$media_target" != /* && "$media_target" != *".."* && "$media_target" != *//* ]] || {
    echo "WAYDROID_MEDIA_TARGET must be a safe path relative to Android storage" >&2
    exit 4
  }
  case "$media_mode" in
    ro|rw) ;;
    *) echo "WAYDROID_MEDIA_MODE must be ro or rw" >&2; exit 5 ;;
  esac
  [[ "$scan_interval" =~ ^[0-9]+$ ]] || {
    echo "WAYDROID_MEDIA_SCAN_INTERVAL must be an integer number of seconds" >&2
    exit 7
  }
  if ((scan_interval > 0 && scan_interval < 60)); then
    echo "WAYDROID_MEDIA_SCAN_INTERVAL must be 0 or at least 60 seconds" >&2
    exit 8
  fi
}

prepare_outer_mount() {
  validate_config
  command -v bindfs >/dev/null || {
    echo "bindfs is required for Waydroid media sharing" >&2
    exit 6
  }
  install -d -m 0755 "$raw_target"
  if mountpoint -q "$raw_target"; then
    # A former bindfs process may have been terminated while Android still
    # held references to the FUSE mount. Detach it without waiting for every
    # app namespace so service restart and host shutdown can never deadlock.
    umount -l "$raw_target" || true
  fi

  if [[ "$media_mode" == ro ]]; then
    bindfs -f -r --multithreaded \
      --force-user=1023 --force-group=1023 \
      --perms='a-w,a+rX' -o allow_other \
      "$effective_media_source" "$raw_target" &
  else
    bindfs -f --multithreaded \
      --force-user=1023 --force-group=1023 \
      --perms='a=rwX' \
      --create-for-user="$desktop_uid" --create-for-group="$desktop_gid" \
      --create-with-perms='u=rwX:g=rwX:o=' \
      --chown-ignore --chgrp-ignore --chmod-ignore --xattr-ro \
      -o allow_other "$effective_media_source" "$raw_target" &
  fi
  bindfs_pid=$!
  for _ in {1..50}; do
    mountpoint -q "$raw_target" && break
    kill -0 "$bindfs_pid" 2>/dev/null || {
      wait "$bindfs_pid" || true
      echo "bindfs exited before mounting $raw_target" >&2
      exit 9
    }
    sleep 0.1
  done
  mountpoint -q "$raw_target" || {
    kill "$bindfs_pid" 2>/dev/null || true
    echo "Timed out preparing Waydroid media mount: $raw_target" >&2
    exit 10
  }
  echo "Waydroid media source prepared: $media_source -> $raw_target ($media_mode)"
}

mount_android_namespaces() {
  local status_file outer_pid nested_pids namespace result mounted_now=0

  # Android gives apps private mount namespaces for scoped storage. A mount in
  # PID 1's /storage is therefore invisible to Gallery and other real apps.
  # Discover every nested-LXC mount namespace and install the same read-only
  # bind there. New app namespaces are picked up by the next watcher pass.
  for status_file in /proc/[0-9]*/status; do
    nested_pids="$(awk '$1 == "NSpid:" {for (i=2; i<=NF; i++) printf "%s%s", $i, (i==NF ? "" : " ")}' \
      "$status_file" 2>/dev/null || true)"
    [[ "$nested_pids" == *" "* ]] || continue
    outer_pid="${status_file#/proc/}"
    outer_pid="${outer_pid%/status}"
    [[ -e "/proc/$outer_pid/root/system/bin/mount" ]] || continue
    namespace="$(readlink "/proc/$outer_pid/ns/mnt" 2>/dev/null || true)"
    [[ -n "$namespace" && -z "${mounted_namespaces[$namespace]:-}" ]] || continue

    if nsenter -t "$outer_pid" -m -p -- /system/bin/sh -c '
      source_path=$1
      target_path=$2
      access_mode=$3
      /system/bin/mkdir -p "$target_path" || exit 1
      if ! /system/bin/grep -Fq " $target_path " /proc/self/mounts; then
        /system/bin/mount --bind "$source_path" "$target_path" || exit 1
        if [ "$access_mode" = ro ]; then
          /system/bin/mount -o remount,bind,ro "$target_path" || exit 1
        fi
      fi
    ' fnos-media "$android_source" "$android_target" "$media_mode" >/dev/null 2>&1; then
      mounted_namespaces["$namespace"]=1
      ((mounted_now += 1))
    fi
  done

  if ((mounted_now > 0)); then
    echo "Waydroid app storage mounted in $mounted_now new namespace(s): $android_target ($media_mode)"
  fi
}

trigger_media_scan() {
  local encoded_path
  ((scan_interval > 0)) || return 0
  encoded_path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' \
    "$android_target")"
  # `am` is a shell wrapper around `cmd` and fails under systemd when Android's
  # interactive PATH is absent. Invoke the framework command directly.
  if ! lxc-attach -P "$lxc_path" -n "$lxc_name" -- \
    /system/bin/cmd activity broadcast \
      -n com.android.providers.media.module/com.android.providers.media.MediaReceiver \
      -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d "file://$encoded_path" --receiver-include-background >/dev/null; then
    echo "Waydroid MediaStore scan request failed: $android_target" >&2
    return 1
  fi
  echo "Waydroid MediaStore recursive scan requested: $android_target"
}

watch_android() {
  local state init_pid boot_completed observed_pid= stable_ticks=0
  local now last_scan=0 scan_pid=
  validate_config
  while true; do
    state="$(lxc-info -P "$lxc_path" -n "$lxc_name" -sH 2>/dev/null || true)"
    if [[ "$state" == FROZEN ]]; then
      # Preserve the namespace cache while Android is merely idle. As soon as
      # the user opens an app Waydroid unfreezes and new namespaces are bridged
      # on the next pass instead of waiting through startup stabilization.
      sleep 2
      continue
    fi
    if [[ "$state" != RUNNING ]]; then
      observed_pid=
      stable_ticks=0
      mounted_namespaces=()
      last_scan=0
      scan_pid=
      sleep 2
      continue
    fi

    init_pid="$(lxc-info -P "$lxc_path" -n "$lxc_name" -pH 2>/dev/null || true)"
    if [[ -z "$init_pid" ]]; then
      sleep 2
      continue
    fi
    if [[ "$init_pid" != "$observed_pid" ]]; then
      observed_pid="$init_pid"
      stable_ticks=0
    else
      ((stable_ticks += 1))
    fi

    # Waydroid may replace its init/storage namespace once during startup even
    # though sys.boot_completed is already 1 from the previous session. Wait
    # for one init PID to remain stable for about 12 seconds before bridging.
    if ((stable_ticks >= 6)); then
      boot_completed="$(lxc-attach -P "$lxc_path" -n "$lxc_name" -- \
        /system/bin/getprop sys.boot_completed 2>/dev/null || true)"
      if [[ "$boot_completed" == 1 ]]; then
        mount_android_namespaces || true
        now="$(date +%s)"
        if [[ "$scan_pid" != "$init_pid" ]] || \
            ((scan_interval > 0 && now - last_scan >= scan_interval)); then
          if trigger_media_scan; then
            scan_pid="$init_pid"
            last_scan="$now"
          fi
        fi
      fi
    fi
    sleep 2
  done
}

cleanup_mounts() {
  local state status_file outer_pid nested_pids namespace
  local -A cleaned_namespaces=()
  state="$(lxc-info -P "$lxc_path" -n "$lxc_name" -sH 2>/dev/null || true)"
  if [[ "$state" == FROZEN ]]; then
    lxc-unfreeze -P "$lxc_path" -n "$lxc_name" >/dev/null 2>&1 || true
    state=RUNNING
  fi
  if [[ "$state" == RUNNING ]]; then
    for status_file in /proc/[0-9]*/status; do
      nested_pids="$(awk '$1 == "NSpid:" {for (i=2; i<=NF; i++) printf "%s%s", $i, (i==NF ? "" : " ")}' \
        "$status_file" 2>/dev/null || true)"
      [[ "$nested_pids" == *" "* ]] || continue
      outer_pid="${status_file#/proc/}"
      outer_pid="${outer_pid%/status}"
      namespace="$(readlink "/proc/$outer_pid/ns/mnt" 2>/dev/null || true)"
      [[ -n "$namespace" && -z "${cleaned_namespaces[$namespace]:-}" ]] || continue
      cleaned_namespaces["$namespace"]=1
      nsenter -t "$outer_pid" -m -p -- /system/bin/sh -c '
        target_path=$1
        /system/bin/umount -l "$target_path" 2>/dev/null || true
      ' fnos-media "$android_target" >/dev/null 2>&1 || true
    done
  fi
  mountpoint -q "$raw_target" && umount -l "$raw_target" || true
}

run_bridge() {
  trap 'exit 0' TERM INT
  trap cleanup_mounts EXIT
  prepare_outer_mount
  systemd-notify --ready --status="Waydroid NAS media bridge is ready"
  watch_android
}

case "${1:-watch}" in
  run) run_bridge ;;
  prepare) prepare_outer_mount ;;
  watch) watch_android ;;
  cleanup) cleanup_mounts ;;
  *) echo "Usage: $0 {run|prepare|watch|cleanup}" >&2; exit 64 ;;
esac
