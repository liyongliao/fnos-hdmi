#!/bin/sh
set -eu

failed=0
for path in /dev/dri/card0 /dev/dri/renderD128 /dev/input /dev/snd /run/udev /sys/fs/cgroup; do
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

echo
echo "Compose GPU isolation:"
if grep -Eq '^[[:space:]]*privileged:[[:space:]]*true' compose.yaml; then
  echo "UNSAFE  privileged mode exposes every SR-IOV VF"
  failed=1
else
  echo "OK      privileged mode is disabled"
fi
if grep -Eq '^[[:space:]]*-[[:space:]]*/dev/dri:/dev/dri' compose.yaml; then
  echo "UNSAFE  the complete /dev/dri directory is exposed"
  failed=1
else
  echo "OK      /dev/dri is not exposed as a directory"
fi
if grep -q '/dev/dri/card0:/dev/dri/card0' compose.yaml && \
   grep -q '/dev/dri/renderD128:/dev/dri/renderD128' compose.yaml; then
  echo "OK      only PF card0 and renderD128 are selected"
else
  echo "MISSING explicit PF card0/renderD128 mappings"
  failed=1
fi

echo
echo "Waydroid Binder support:"
binder_major="$(awk '$2 == "binder" {print $1; exit}' /proc/devices)"
if [ -n "$binder_major" ]; then
  echo "OK      binderfs is available (character major $binder_major)"
  if grep -q 'BINDER_DEVICE_MAJOR' compose.yaml; then
    echo "OK      Compose has a scoped Binder device rule"
  else
    echo "MISSING Compose Binder device rule"
    failed=1
  fi
else
  echo "MISSING fnOS kernel binderfs support; Waydroid cannot run"
fi

exit "$failed"
