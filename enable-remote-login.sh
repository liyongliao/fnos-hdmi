#!/bin/bash
set -euo pipefail

if [[ -r /run/fnos-desktop.env ]]; then
  # shellcheck disable=SC1091
  source /run/fnos-desktop.env
fi

desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_password="${DESKTOP_PASSWORD:-}"
remote_login_user="${REMOTE_LOGIN_USER:-$desktop_user}"
remote_login_password="${REMOTE_LOGIN_PASSWORD:-$desktop_password}"
service_home=/var/lib/gnome-remote-desktop
state_dir="$service_home/.local/share/gnome-remote-desktop"
tls_key="$state_dir/rdp-tls.key"
tls_cert="$state_dir/rdp-tls.crt"

if [[ -z "$remote_login_user" || -z "$remote_login_password" ]]; then
  echo "Remote Login credentials are unavailable." >&2
  exit 13
fi

run_grdctl() {
  runuser -u gnome-remote-desktop -- \
    env HOME="$service_home" grdctl --system "$@"
}

install -d -m 0700 -o gnome-remote-desktop -g gnome-remote-desktop "$state_dir"
if [[ ! -f "$tls_key" || ! -f "$tls_cert" ]]; then
  runuser -u gnome-remote-desktop -- openssl req \
    -new -newkey rsa:3072 -days 730 -nodes -x509 \
    -subj "/CN=$(hostname)" -out "$tls_cert" -keyout "$tls_key"
fi

run_grdctl rdp set-tls-key "$tls_key"
run_grdctl rdp set-tls-cert "$tls_cert"
run_grdctl rdp set-port 3389
run_grdctl rdp disable-port-negotiation

# Ubuntu 26.04's grdctl accepts omitted credential arguments without an error,
# but in a non-interactive systemd service that stores empty credentials. Run
# it directly as the dedicated service account and pass the protected in-memory
# values as arguments. This avoids pkexec recording the secret in the journal.
run_grdctl rdp set-credentials "$remote_login_user" "$remote_login_password"
run_grdctl rdp enable

status="$(grdctl --system status)"
printf '%s\n' "$status"
if grep -q 'Credentials are not set' <<<"$status" || \
   grep -qE 'Username: \(empty\)|Password: \(empty\)' <<<"$status"; then
  echo "GNOME Remote Login rejected the configured credentials." >&2
  exit 14
fi
