#!/bin/bash
set -euo pipefail

if [[ -r /run/fnos-desktop.env ]]; then
  # shellcheck disable=SC1091
  source /run/fnos-desktop.env
fi

desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_password="${DESKTOP_PASSWORD:-}"
state_dir=/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop
tls_key="$state_dir/rdp-tls.key"
tls_cert="$state_dir/rdp-tls.crt"

if [[ -z "$desktop_password" ]]; then
  echo "DESKTOP_PASSWORD is unavailable." >&2
  exit 13
fi

install -d -m 0700 -o gnome-remote-desktop -g gnome-remote-desktop "$state_dir"
if [[ ! -f "$tls_key" || ! -f "$tls_cert" ]]; then
  runuser -u gnome-remote-desktop -- openssl req \
    -new -newkey rsa:3072 -days 730 -nodes -x509 \
    -subj "/CN=$(hostname)" -out "$tls_cert" -keyout "$tls_key"
fi

grdctl --system rdp set-tls-key "$tls_key"
grdctl --system rdp set-tls-cert "$tls_cert"
grdctl --system rdp set-port 3389
grdctl --system rdp disable-port-negotiation
# Omit credentials from argv: pkexec records the command line in the journal.
# grdctl accepts the same values interactively from stdin without exposing the
# password in process listings or service logs.
printf '%s\n%s\n' "$desktop_user" "$desktop_password" | \
  grdctl --system rdp set-credentials
grdctl --system rdp enable
grdctl --system status
