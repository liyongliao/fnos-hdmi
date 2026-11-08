#!/bin/sh
set -eu

failed=0
drm_card=/dev/dri/card0
drm_render=/dev/dri/renderD128
if [ -f .env ]; then
  configured_card="$(awk -F= '$1 == "DRM_CARD_DEVICE" {print $2; exit}' .env)"
  configured_render="$(awk -F= '$1 == "DRM_RENDER_DEVICE" {print $2; exit}' .env)"
  drm_card="${configured_card:-$drm_card}"
  drm_render="${configured_render:-$drm_render}"
fi

for path in "$drm_card" "$drm_render" /dev/input /dev/snd /run/udev /sys/fs/cgroup; do
  if [ -e "$path" ]; then
    echo "OK      $path"
  else
    echo "MISSING $path"
    failed=1
  fi
done

echo
echo "GPU devices:"
ls -l /dev/dri 2>/dev/null || true
echo "Selected display devices: $drm_card + $drm_render"

echo
echo "DRM display connectors:"
connected_count=0
connector_count=0
for status_file in /sys/class/drm/card*-*/status; do
  [ -e "$status_file" ] || continue
  connector_count=$((connector_count + 1))
  connector_name="${status_file%/status}"
  connector_name="${connector_name##*/}"
  connector_status="$(cat "$status_file")"
  [ "$connector_status" = connected ] && connected_count=$((connected_count + 1))
  printf '%-24s %s\n' "$connector_name" "$connector_status"
done
if [ "$connector_count" -eq 0 ]; then
  echo "MISSING no HDMI/DP/eDP connector is exposed by the selected GPU driver"
  failed=1
elif [ "$connected_count" -eq 0 ]; then
  echo "WARN    no connector is active; configure the README headless EDID step before expecting HDMI/RDP screen sharing"
fi

echo
echo "Sound devices:"
cat /proc/asound/cards 2>/dev/null || true

echo
echo "Processes already using DRM devices:"
if command -v fuser >/dev/null 2>&1; then
  fuser -v /dev/dri/card* 2>/dev/null || true
else
  echo "fuser is not installed"
fi

echo
echo "SR-IOV state:"
if [ -r /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs ]; then
  printf 'enabled VFs: '
  cat /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs
fi

privileged_mode=true
limit_gpu=true
if [ -f .env ]; then
  privileged_mode="$(awk -F= '$1 == "PRIVILEGED_MODE" {print tolower($2); exit}' .env)"
  privileged_mode="${privileged_mode:-true}"
  limit_gpu="$(awk -F= '$1 == "LIMIT_GPU_DEVICES" {print tolower($2); exit}' .env)"
  limit_gpu="${limit_gpu:-true}"
fi

echo
echo "Docker compatibility mode:"
if [ "$privileged_mode" = true ]; then
  echo "OK      privileged compatibility mode is enabled"
  if [ "$limit_gpu" = true ]; then
    echo "OK      extra DRM nodes will be hidden inside the container"
  else
    echo "INFO    all privileged DRM nodes remain visible to GNOME"
  fi
else
  echo "OK      scoped capability/device mode is enabled"
fi

if grep -Fq '${DRM_CARD_DEVICE:-/dev/dri/card0}:${DRM_CARD_DEVICE:-/dev/dri/card0}' compose.yaml && \
   grep -Fq '${DRM_RENDER_DEVICE:-/dev/dri/renderD128}:${DRM_RENDER_DEVICE:-/dev/dri/renderD128}' compose.yaml; then
  echo "OK      container device paths match the host DRM paths"
else
  echo "MISSING variable DRM device mappings in compose.yaml"
  failed=1
fi

echo
echo "Waydroid Binder support:"
binder_major="$(awk '$2 == "binder" {print $1; exit}' /proc/devices)"
if [ -n "$binder_major" ]; then
  echo "OK      binderfs is available (character major $binder_major)"
  if grep -q 'BINDER_DEVICE_MAJOR' compose.yaml; then
    echo "OK      Compose records Binder access for scoped mode"
  else
    echo "MISSING Compose Binder device rule"
    failed=1
  fi
else
  echo "MISSING fnOS kernel binderfs support; Waydroid cannot run"
  failed=1
fi

waydroid_requested=false
if [ -f .env ] && grep -Eqi '^INSTALL_WAYDROID=true[[:space:]]*$' .env; then
  waydroid_requested=true
fi

if [ "$waydroid_requested" = true ]; then
  echo
  echo "Waydroid loop support:"
  loop_major="$(awk '$2 == "loop" {print $1; exit}' /proc/devices)"
  if [ -n "$loop_major" ]; then
    echo "OK      Linux loop block driver is available (major $loop_major)"
  else
    echo "MISSING Linux loop driver; run 'sudo modprobe loop' on fnOS"
    failed=1
  fi

  if [ "$privileged_mode" = true ]; then
    echo "OK      privileged mode grants loop/LXC device access"
  elif grep -Fq '"c 10:237 rmw"' compose.yaml && grep -Fq '"b 7:* rmw"' compose.yaml; then
    echo "OK      scoped mode allows loop-control and loop block devices"
  else
    echo "MISSING scoped single-runtime loop device rules"
    failed=1
  fi
fi

echo
echo "Docker outbound network prerequisites:"
if ip route show default | grep -q '^default '; then
  echo "OK      fnOS has a default IPv4 route"
else
  echo "MISSING fnOS default IPv4 route"
  failed=1
fi
if getent hosts repo.waydro.id >/dev/null 2>&1; then
  echo "OK      fnOS DNS resolves repo.waydro.id"
else
  echo "WARN    fnOS DNS cannot currently resolve repo.waydro.id"
fi

echo
echo "Remote access binding:"
bind_address=0.0.0.0
if [ -f .env ]; then
  bind_address="$(awk -F= '$1 == "BIND_ADDRESS" {print $2; exit}' .env)"
  bind_address="${bind_address:-0.0.0.0}"
fi
echo "INFO    RDP/Web services bind to $bind_address"

exit "$failed"
