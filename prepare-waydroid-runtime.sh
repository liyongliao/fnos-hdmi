#!/bin/bash
set -euo pipefail

root=/var/lib/waydroid
system_img="$root/images/system.img"
vendor_img="$root/images/vendor.img"
cfg="$root/waydroid.cfg"
base_prop="$root/waydroid_base.prop"
mount_dir=/run/fnos-waydroid-system
marker="$root/.fnos-runtime-prepared"

# The Waydroid container daemon is allowed to run before first-launch. Until
# initialization has produced all required files there is simply nothing to do.
for required in "$cfg" "$base_prop" "$system_img" "$vendor_img"; do
  [[ -s "$required" ]] || exit 0
done

# Re-run only when an Android image itself changed. prepare-waydroid-android.py
# intentionally rewrites waydroid.cfg/base.prop, so including their mtimes here
# would make the marker change on every session.
fingerprint="$({ stat -Lc '%n:%s:%Y' "$system_img" "$vendor_img"; } | sha256sum | awk '{print $1}')"
if [[ -s "$marker" ]] && [[ "$(cat "$marker")" == "$fingerprint" ]]; then
  exit 0
fi

cleanup() {
  if mountpoint -q "$mount_dir" 2>/dev/null; then
    umount "$mount_dir" || true
  fi
}
trap cleanup EXIT

install -d -m 0755 "$mount_dir"

# util-linux mount automatically allocates a loop device for a regular image.
# The Docker container has access only to Linux loop major 7, never fnOS disks.
mount -o ro "$system_img" "$mount_dir"
python3 /usr/local/sbin/prepare-waydroid-android.py "$mount_dir"
umount "$mount_dir"

printf '%s\n' "$fingerprint" >"$marker"
echo "fnOS Waydroid runtime preparation complete" >&2
