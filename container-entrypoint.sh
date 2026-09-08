#!/bin/bash
set -euo pipefail

if [[ -f /usr/local/sbin/configure-waydroid.py ]]; then
  python3 /usr/local/sbin/configure-waydroid.py
fi

# One runtime only: if Waydroid is installed, prepare loop device nodes inside
# Docker's private /dev from the start. Linux loop devices are kernel-global,
# but the cgroup rule in compose.yaml permits only block major 7 (loop), not
# fnOS physical/LVM/NVMe disks. This lets util-linux mount system.img directly
# without a host-side losetup + Docker recreate step.
if command -v waydroid >/dev/null 2>&1; then
  if [[ ! -e /dev/loop-control ]]; then
    if ! mknod -m 0600 /dev/loop-control c 10 237; then
      echo "WARNING: cannot create /dev/loop-control; Waydroid image mounting may fail." >&2
    fi
  fi
  for loop_minor in $(seq 0 255); do
    loop_node="/dev/loop${loop_minor}"
    [[ -e "$loop_node" ]] || mknod -m 0600 "$loop_node" b 7 "$loop_minor" 2>/dev/null || true
  done
fi

# Docker mounts a private cgroup v2 namespace read-only for non-privileged
# containers on fnOS. systemd needs to create init.scope below that private
# root; remount only this namespaced view instead of bind-mounting the host's
# complete /sys/fs/cgroup tree.
if ! test -w /sys/fs/cgroup; then
  mount -o remount,rw /sys/fs/cgroup
fi

# Compile the bind-mounted login-screen override before GDM starts. It avoids
# a GNOME Shell 50 LoginDialog crash when its headless renderer cannot load the
# Ubuntu SVG logo.
glib-compile-schemas /usr/share/glib-2.0/schemas

# The container can see the host kernel's block-device metadata through sysfs
# and /run/udev, but Docker intentionally does not expose the corresponding
# /dev/dm-* nodes. Letting udisks enumerate those host volumes creates
# misleading Nautilus entries which cannot be mounted safely from here.
# Host storage is exposed as ordinary bind mounts by setup-storage.sh instead.
if [[ "${DISABLE_UDISKS:-true}" == true ]]; then
  install -d -m 0755 /run/systemd/system
  ln -sfn /dev/null /run/systemd/system/udisks2.service
fi

# Select exactly one GNOME RDP role. Remote Login must own the system daemon
# and must not race the per-user Desktop Sharing service.
remote_mode="${REMOTE_MODE:-both}"
for remote_unit in fnos-desktop-sharing.service fnos-remote-login.service; do
  if [[ ! -f "/etc/systemd/system/$remote_unit" ]]; then
    echo "Missing $remote_unit: update compose.yaml and recreate the container." >&2
    exit 15
  fi
done
install -d /etc/systemd/system/graphical.target.wants
for remote_unit in fnos-desktop-sharing.service fnos-remote-login.service; do
  ln -sfn "/etc/systemd/system/$remote_unit" "/etc/systemd/system/graphical.target.wants/$remote_unit"
done
ln -sfn /usr/lib/systemd/system/gnome-remote-desktop.service \
  /etc/systemd/system/graphical.target.wants/gnome-remote-desktop.service
desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_uid="${DESKTOP_UID:-1000}"
desktop_gid="${DESKTOP_GID:-1000}"
case "$remote_mode" in
  login)
    rm -f /etc/systemd/system/graphical.target.wants/fnos-desktop-sharing.service
    ;;
  share)
    rm -f \
      /etc/systemd/system/graphical.target.wants/fnos-remote-login.service \
      /etc/systemd/system/graphical.target.wants/gnome-remote-desktop.service
    ;;
  both)
    # Keep both units: system Remote Login owns 3389 while the user desktop
    # sharing daemon owns 3390.
    ;;
  *)
    echo "REMOTE_MODE must be 'both', 'login' or 'share'" >&2
    exit 5
    ;;
esac

# systemd deliberately starts services with a clean environment. Keep the
# Compose values in /run (tmpfs) so the boot-time sharing service can read them
# without persisting the desktop password in the image.
umask 077
{
  printf 'DESKTOP_USER=%q\n' "$desktop_user"
  printf 'DESKTOP_PASSWORD=%q\n' "${DESKTOP_PASSWORD:-}"
  printf 'REMOTE_LOGIN_USER=%q\n' "${REMOTE_LOGIN_USER:-$desktop_user}"
  printf 'REMOTE_LOGIN_PASSWORD=%q\n' "${REMOTE_LOGIN_PASSWORD:-${DESKTOP_PASSWORD:-}}"
  printf 'DESKTOP_SHARING_PORT=%q\n' "${DESKTOP_SHARING_PORT:-3390}"
  printf 'SCREEN_SHARE_MODE=%q\n' "${SCREEN_SHARE_MODE:-mirror-primary}"
} >/run/fnos-desktop.env

if ! [[ "$desktop_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "DESKTOP_USER is not a valid Linux account name" >&2
  exit 2
fi

if ! id "$desktop_user" >/dev/null 2>&1; then
  uid_owner="$(getent passwd "$desktop_uid" | cut -d: -f1 || true)"
  if [[ -n "$uid_owner" ]]; then
    echo "UID $desktop_uid already belongs to $uid_owner; set DESKTOP_USER=$uid_owner" >&2
    exit 3
  fi
  getent group "$desktop_gid" >/dev/null || groupadd --gid "$desktop_gid" "$desktop_user"
  useradd --uid "$desktop_uid" --gid "$desktop_gid" --create-home \
    --shell /bin/bash "$desktop_user"
fi

getent group admin >/dev/null || groupadd --system admin
usermod -aG sudo,admin,audio,video,input,render "$desktop_user"

# Device group numbers come from fnOS and may map to different group names in
# Ubuntu (for example fnOS render=105 while Ubuntu render=992). Add the user
# to the groups owning the actual bind-mounted devices before GDM logs in.
for device_path in /dev/dri/card0 /dev/dri/renderD128 /dev/input/event0 /dev/snd/controlC0; do
  [[ -e "$device_path" ]] || continue
  device_gid="$(stat -c '%g' "$device_path")"
  device_group="$(getent group "$device_gid" | cut -d: -f1 || true)"
  if [[ -z "$device_group" ]]; then
    device_group="fnos-device-$device_gid"
    groupadd --gid "$device_gid" "$device_group"
  fi
  usermod -aG "$device_group" "$desktop_user"
done

if [[ -z "${DESKTOP_PASSWORD:-}" ]]; then
  echo "DESKTOP_PASSWORD must be set" >&2
  exit 4
fi
printf '%s:%s\n' "$desktop_user" "$DESKTOP_PASSWORD" | chpasswd

actual_uid="$(id -u "$desktop_user")"
actual_gid="$(id -g "$desktop_user")"
install -d -o "$actual_uid" -g "$actual_gid" "/home/$desktop_user"
chown "$actual_uid:$actual_gid" "/home/$desktop_user"

# fnOS trimacl permissions are intentionally enforced on /volN even when the
# numeric UID matches. A small bindfs view lets the desktop user access only
# the explicitly bind-mounted /volN/<uid> trees without changing host ACLs.
storage_raw_root="${NAS_STORAGE_RAW_ROOT:-/mnt/fnos-raw}"
storage_root="${NAS_STORAGE_ROOT:-/mnt/fnos}"
if [[ -d "$storage_raw_root" ]]; then
  if ! command -v bindfs >/dev/null; then
    echo "NAS storage is configured but bindfs is missing from the image." >&2
    exit 6
  fi
  install -d -m 0755 "$storage_root"
  shopt -s nullglob
  for raw_storage_path in "$storage_raw_root"/*; do
    [[ -d "$raw_storage_path" ]] || continue
    storage_name="${raw_storage_path##*/}"
    storage_path="$storage_root/$storage_name"
    install -d -m 0755 "$storage_path"
    bindfs \
      --force-user="$actual_uid" \
      --force-group="$actual_gid" \
      --perms='u=rwX:g=:o=' \
      --create-for-user="${NAS_BACKING_UID:-$actual_uid}" \
      --create-for-group="${NAS_BACKING_GID:-$actual_gid}" \
      --create-with-perms='u=rwX:g=rwX:o=' \
      --chown-ignore --chgrp-ignore --chmod-ignore --xattr-ro \
      -o allow_other "$raw_storage_path" "$storage_path"
  done
  shopt -u nullglob
fi

# Add friendly home-directory shortcuts for each prepared NAS storage view.
if [[ -d "$storage_root" ]]; then
  shopt -s nullglob
  for storage_path in "$storage_root"/*; do
    [[ -d "$storage_path" ]] || continue
    storage_name="${storage_path##*/}"
    shortcut="/home/$desktop_user/NAS-$storage_name"
    if [[ ! -e "$shortcut" && ! -L "$shortcut" ]]; then
      ln -s "$storage_path" "$shortcut"
      chown -h "$actual_uid:$actual_gid" "$shortcut"
    fi
  done
  shopt -u nullglob
fi

install -d -m 0755 /var/lib/AccountsService/users
cat >"/var/lib/AccountsService/users/$desktop_user" <<EOF
[User]
Language=zh_CN.UTF-8
XSession=ubuntu
SystemAccount=false
EOF
chmod 0600 "/var/lib/AccountsService/users/$desktop_user"

# A local auto-login session occupies the same account and can make GDM reject
# a Remote Login request. Keep GDM at its login screen in system-login mode.
if [[ "$remote_mode" == login ]]; then
  auto_login=false
else
  auto_login="${AUTO_LOGIN:-true}"
fi
cat >/etc/gdm3/custom.conf <<EOF
[daemon]
WaylandEnable=true
AutomaticLoginEnable=$auto_login
AutomaticLogin=$desktop_user
EOF

exec "$@"
