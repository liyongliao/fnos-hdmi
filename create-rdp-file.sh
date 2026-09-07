#!/usr/bin/env bash
set -euo pipefail

server="${1:-}"
port="${2:-3391}"
output="${3:-fnos-remote-login.rdp}"
username="${4:-ubuntu}"

if [[ -z "$server" ]]; then
  echo "用法: $0 <fnOS-IP> [端口] [输出文件] [用户名]" >&2
  echo "示例: $0 192.168.31.100 3391 fnos-remote-login.rdp ubuntu" >&2
  exit 2
fi

if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo "端口必须是 1-65535 的数字。" >&2
  exit 2
fi

# GNOME Remote Login uses a locally generated TLS certificate by default.
# Authentication level 0 keeps TLS encryption but accepts that local certificate.
cat >"$output" <<EOF
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
dynamic resolution:i:1
compression:i:1
keyboardhook:i:2
audiocapturemode:i:1
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
allow font smoothing:i:1
allow desktop composition:i:1
bitmapcachepersistenable:i:1
full address:s:${server}:${port}
username:s:${username}
audiomode:i:0
redirectprinters:i:0
redirectcomports:i:0
redirectsmartcards:i:0
redirectclipboard:i:1
autoreconnection enabled:i:1
authentication level:i:0
prompt for credentials:i:1
promptcredentialonce:i:0
negotiate security layer:i:1
enablecredsspsupport:i:1
remoteapplicationmode:i:0
gatewayusagemethod:i:4
use redirection server name:i:1
EOF

chmod 0600 "$output"
printf '已生成: %s\n' "$output"
printf '请双击或使用 Windows App / mstsc 导入该文件。\n'
