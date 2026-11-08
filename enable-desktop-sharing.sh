#!/bin/bash
set -euo pipefail

if [[ -r /run/fnos-desktop.env ]]; then
  # Written by the container entrypoint with bash-safe escaping.
  # shellcheck disable=SC1091
  source /run/fnos-desktop.env
fi

desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_uid="$(id -u "$desktop_user")"
desktop_gid="$(id -g "$desktop_user")"
desktop_home="$(getent passwd "$desktop_user" | cut -d: -f6)"
runtime_dir="/run/user/$desktop_uid"
bus_address="unix:path=$runtime_dir/bus"

# graphical.target and this oneshot can race GDM automatic login. Wait for the
# real seat0 Wayland session instead of logging a misleading FAILED line during
# an otherwise healthy boot. A genuinely missing KMS output still fails with a
# useful headless/DRM hint after the grace period.
session_id=
session_type=
for _ in {1..45}; do
  session_id=
  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "$(loginctl show-session "$candidate" -p Seat --value 2>/dev/null)" == seat0 ]] || continue
    [[ "$(loginctl show-session "$candidate" -p Type --value 2>/dev/null)" == wayland ]] || continue
    session_id=$candidate
    break
  done < <(loginctl list-sessions --no-legend | awk -v uid="$desktop_uid" '$2 == uid {print $1}')
  if [[ -n "$session_id" ]]; then
    session_type="$(loginctl show-session "$session_id" -p Type --value)"
    [[ "$session_type" == wayland && -S "$runtime_dir/bus" ]] && break
  fi
  sleep 2
done
if [[ -z "$session_id" ]]; then
  echo "No seat0 desktop session for $desktop_user. Check AUTO_LOGIN and the host DRM/virtual-HDMI configuration." >&2
  exit 10
fi
if [[ "$session_type" != wayland ]]; then
  echo "Session $session_id is $session_type, expected wayland. Check GDM and the selected DRM device." >&2
  exit 11
fi
if [[ ! -S "$runtime_dir/bus" ]]; then
  echo "The user D-Bus is unavailable after waiting for automatic login." >&2
  exit 12
fi

as_user() {
  runuser -u "$desktop_user" -- env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$bus_address" \
    "$@"
}

# Mutter deliberately rejects creation of a RemoteDesktop session while the
# physical Wayland session is locked.  This appliance-style desktop must stay
# shareable after an unattended/headless boot, so disable the idle lock and
# automatic suspend before starting GNOME Remote Desktop.  Also unlock a
# session which may already have reached the default five-minute timeout.
as_user gsettings set org.gnome.desktop.session idle-delay 'uint32 0'
as_user gsettings set org.gnome.desktop.screensaver lock-enabled false
as_user gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
as_user gsettings set org.gnome.desktop.lockdown disable-lock-screen true
as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
loginctl unlock-session "$session_id" || true

tls_dir="$desktop_home/.local/share/gnome-remote-desktop"
install -d -m 700 -o "$desktop_uid" -g "$desktop_gid" "$tls_dir"
if [[ ! -f "$tls_dir/tls.key" || ! -f "$tls_dir/tls.crt" ]]; then
  as_user openssl req -new -newkey rsa:3072 -days 730 -nodes -x509 \
    -subj "/CN=$(hostname)" \
    -out "$tls_dir/tls.crt" -keyout "$tls_dir/tls.key"
  chmod 0600 "$tls_dir/tls.key"
fi

as_user grdctl rdp set-tls-key "$tls_dir/tls.key"
as_user grdctl rdp set-tls-cert "$tls_dir/tls.crt"
as_user grdctl rdp set-port "${DESKTOP_SHARING_PORT:-3390}"
as_user grdctl rdp disable-port-negotiation
as_user grdctl rdp disable-view-only

if [[ -z "${DESKTOP_PASSWORD:-}" ]]; then
  echo "DESKTOP_PASSWORD is unavailable in the container environment." >&2
  exit 13
fi
# Screen-sharing mode normally stores credentials in the login keyring.  GDM
# automatic login cannot unlock that keyring.  Inject the supported daemon
# credential override into the per-user systemd manager on every boot instead;
# the secret stays in /run and the keyring prompt is never triggered.
as_user systemctl --user set-environment \
  "GNOME_REMOTE_DESKTOP_TEST_RDP_USERNAME=$desktop_user" \
  "GNOME_REMOTE_DESKTOP_TEST_RDP_PASSWORD=$DESKTOP_PASSWORD"

as_user gsettings set org.gnome.desktop.remote-desktop.rdp \
  screen-share-mode "${SCREEN_SHARE_MODE:-mirror-primary}"
as_user grdctl rdp enable
as_user systemctl --user daemon-reload
as_user systemctl --user enable --now gnome-remote-desktop.service
as_user systemctl --user restart gnome-remote-desktop.service
as_user grdctl status
