#!/bin/bash
set -euo pipefail

mode="${1:-}"

configure_system() {
  install -d -m 0755 /etc/polkit-1/rules.d /etc/dconf/db/local.d \
    /etc/dconf/db/local.d/locks /etc/systemd/system /etc/systemd/user

  # This image is an appliance desktop, not a multi-user workstation. Keep
  # polkit functional so GNOME APIs still work, but authorize every request.
  install -m 0644 /usr/local/share/fnos/00-fnos-appliance.rules \
    /etc/polkit-1/rules.d/00-fnos-appliance.rules
  install -m 0644 /usr/local/share/fnos/00-fnos-appliance.gschema.override \
    /usr/share/glib-2.0/schemas/00-fnos-appliance.gschema.override
  glib-compile-schemas /usr/share/glib-2.0/schemas
  install -m 0644 /usr/local/share/fnos/dconf-user-profile /etc/dconf/profile/user
  install -m 0644 /usr/local/share/fnos/00-fnos-appliance.dconf \
    /etc/dconf/db/local.d/00-fnos-appliance
  install -m 0644 /usr/local/share/fnos/00-fnos-appliance.locks \
    /etc/dconf/db/local.d/locks/00-fnos-appliance
  if command -v dconf >/dev/null 2>&1; then
    dconf update
  fi

  # Docker appliance images must not wake the TV session with host-style
  # package upgrades, crash reporting, release prompts, or welcome services.
  for unit in \
    apt-daily.service apt-daily.timer \
    apt-daily-upgrade.service apt-daily-upgrade.timer \
    unattended-upgrades.service whoopsie.service apport.service \
    ua-timer.service ua-timer.timer; do
    ln -sfn /dev/null "/etc/systemd/system/$unit"
  done
  for unit in \
    update-notifier-crash.path update-notifier-crash.service \
    update-notifier-livepatch.path update-notifier-livepatch.service \
    update-notifier-release.path update-notifier-release.service \
    gnome-initial-setup.service; do
    ln -sfn /dev/null "/etc/systemd/user/$unit"
  done

  install -d -m 0755 /etc/apt/apt.conf.d
  install -m 0644 /usr/local/share/fnos/99-fnos-no-automatic-updates \
    /etc/apt/apt.conf.d/99-fnos-no-automatic-updates
}

configure_user() {
  local desktop_user="${2:?desktop user is required}"
  local passwd_line desktop_home desktop_uid desktop_gid
  passwd_line="$(getent passwd "$desktop_user")"
  desktop_home="$(cut -d: -f6 <<<"$passwd_line")"
  desktop_uid="$(cut -d: -f3 <<<"$passwd_line")"
  desktop_gid="$(cut -d: -f4 <<<"$passwd_line")"

  install -d -m 0700 -o "$desktop_uid" -g "$desktop_gid" \
    "$desktop_home/.config" "$desktop_home/.config/autostart" \
    "$desktop_home/.local/share/dbus-1/services"
  touch "$desktop_home/.config/gnome-initial-setup-done"
  chown "$desktop_uid:$desktop_gid" "$desktop_home/.config/gnome-initial-setup-done"

  for name in update-notifier ubuntu-advantage-notification \
    gnome-initial-setup-first-login; do
    install -m 0644 -o "$desktop_uid" -g "$desktop_gid" \
      /usr/local/share/fnos/hidden-autostart.desktop \
      "$desktop_home/.config/autostart/$name.desktop"
  done

  # User data directories take precedence over /usr/share for D-Bus service
  # activation. These local stubs keep Online Accounts and its identity/volume
  # helpers from being activated in the television session.
  while read -r service bus_name; do
    install -m 0644 -o "$desktop_uid" -g "$desktop_gid" \
      /usr/local/share/fnos/disabled-dbus.service \
      "$desktop_home/.local/share/dbus-1/services/$service"
    sed -i "s|@BUS_NAME@|$bus_name|" \
      "$desktop_home/.local/share/dbus-1/services/$service"
  done <<'EOF'
org.gnome.OnlineAccounts.service org.gnome.OnlineAccounts
org.gnome.Identity.service org.gnome.Identity
org.gtk.vfs.GoaVolumeMonitor.service org.gtk.vfs.GoaVolumeMonitor
EOF
}

case "$mode" in
  --system) configure_system ;;
  --user) configure_user "$@" ;;
  *) echo "Usage: $0 --system | --user USER" >&2; exit 2 ;;
esac
