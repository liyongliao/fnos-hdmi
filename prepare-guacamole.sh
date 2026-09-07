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
web_user="${WEB_USER:-$desktop_user}"
web_password="${WEB_PASSWORD:-$desktop_password}"

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
desktop_user_xml="$(xml_escape "$desktop_user")"
web_password_md5="$(printf '%s' "$web_password" | md5sum | awk '{print $1}')"

if [[ "$web_user" != "$desktop_user" || "$web_password" != "$desktop_password" ]]; then
  echo "The lightweight web profile requires WEB_USER/WEB_PASSWORD to match the desktop account." >&2
  echo "Use Guacamole's database authentication before exposing it outside the LAN." >&2
  exit 4
fi

install -d -m 0755 "$project_dir/guacamole"
umask 077
cat >"$project_dir/guacamole/user-mapping.xml" <<EOF
<user-mapping>
  <authorize username="$web_user_xml" password="$web_password_md5" encoding="md5">
    <connection name="GNOME Wayland Desktop">
      <protocol>rdp</protocol>
      <param name="hostname">ubuntu26-gnome-hdmi</param>
      <param name="port">3390</param>
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
