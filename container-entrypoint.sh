#!/bin/bash
set -euo pipefail

# Docker mounts a private cgroup v2 namespace read-only for non-privileged
# containers on fnOS.  systemd needs to create init.scope below that private
# root; remount only this namespaced view instead of bind-mounting the host's
# complete /sys/fs/cgroup tree.
if ! test -w /sys/fs/cgroup; then
  mount -o remount,rw /sys/fs/cgroup
fi

# Compile the bind-mounted login-screen override before GDM starts.  It avoids
# a GNOME Shell 50 LoginDialog crash when its headless renderer cannot load the
# Ubuntu SVG logo.
glib-compile-schemas /usr/share/glib-2.0/schemas

# Select exactly one GNOME RDP role.  Remote Login must own the system daemon
# and must not race the per-user Desktop Sharing service.
remote_mode="${REMOTE_MODE:-both}"
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

desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_uid="${DESKTOP_UID:-1000}"
desktop_gid="${DESKTOP_GID:-1000}"

# systemd deliberately starts services with a clean environment.  Keep the
# Compose values in /run (tmpfs) so the boot-time sharing service can read them
# without persisting the desktop password in the image.
umask 077
{
  printf 'DESKTOP_USER=%q\n' "$desktop_user"
  printf 'DESKTOP_PASSWORD=%q\n' "${DESKTOP_PASSWORD:-}"
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
# Ubuntu (for example fnOS render=105 while Ubuntu render=992).  Add the user
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

install -d -m 0755 /var/lib/AccountsService/users
cat >"/var/lib/AccountsService/users/$desktop_user" <<EOF
[User]
Language=zh_CN.UTF-8
XSession=ubuntu
SystemAccount=false
EOF
chmod 0600 "/var/lib/AccountsService/users/$desktop_user"

# A local auto-login session occupies the same account and can make GDM reject
# a Remote Login request.  Keep GDM at its login screen in system-login mode.
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
