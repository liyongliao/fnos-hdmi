#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
env_file="$project_dir/.env"

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file; copy .env.example to .env first." >&2
  exit 2
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

desktop_user="${DESKTOP_USER:-ubuntu}"
desktop_password="${DESKTOP_PASSWORD:-}"
case "${REMOTE_MODE:-both}" in
  both|login)
    target_port=3389
    connection_name="GNOME Remote Login"
    rdp_user="${REMOTE_LOGIN_USER:-$desktop_user}"
    rdp_password="${REMOTE_LOGIN_PASSWORD:-$desktop_password}"
    ;;
  share)
    target_port=3390
    connection_name="GNOME Desktop Sharing"
    rdp_user="$desktop_user"
    rdp_password="$desktop_password"
    ;;
  *) echo "Invalid REMOTE_MODE" >&2; exit 2 ;;
esac
web_user="${WEB_USER:-$rdp_user}"
web_password="${WEB_PASSWORD:-$rdp_password}"

if [[ -z "$desktop_password" || -z "$web_password" ]]; then
  echo "DESKTOP_PASSWORD and WEB_PASSWORD must not be empty." >&2
  exit 3
fi

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

web_user_xml="$(xml_escape "$web_user")"
web_password_md5="$(printf '%s' "$web_password" | md5sum | awk '{print $1}')"

if [[ "$web_user" != "$rdp_user" || "$web_password" != "$rdp_password" ]]; then
  echo "WEB_USER/WEB_PASSWORD must match the selected RDP service credentials." >&2
  echo "Use Guacamole's database authentication before exposing it outside the LAN." >&2
  exit 4
fi

install -d -m 0755 "$project_dir/guacamole"
umask 077
cat >"$project_dir/guacamole/user-mapping.xml" <<EOF
<user-mapping>
  <authorize username="$web_user_xml" password="$web_password_md5" encoding="md5">
    <connection name="$connection_name">
      <protocol>rdp</protocol>
      <param name="hostname">ubuntu26-gnome-hdmi</param>
      <param name="port">$target_port</param>
      <param name="username">\${GUAC_USERNAME}</param>
      <param name="password">\${GUAC_PASSWORD}</param>
      <param name="security">any</param>
      <param name="ignore-cert">true</param>
      <param name="resize-method">display-update</param>
      <param name="enable-audio">true</param>
    </connection>
  </authorize>
</user-mapping>
EOF
chmod 0644 "$project_dir/guacamole/user-mapping.xml"
echo "Created guacamole/user-mapping.xml for web user: $web_user"
