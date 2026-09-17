#!/bin/bash
set -u

container="${1:-ubuntu26-gnome-hdmi}"

echo "=== fnOS host ==="
ip -4 route show default || true
printf 'DNS: '
awk '/^nameserver / {printf "%s ", $2} END {print ""}' /etc/resolv.conf 2>/dev/null || true

echo
echo "=== Ubuntu container ==="
sudo docker exec "$container" bash -lc '
  echo "route:"
  ip -4 route || true
  echo
  echo "resolv.conf:"
  cat /etc/resolv.conf || true
  echo
  python3 - <<"PY"
import socket
for host in ("repo.waydro.id", "archive.ubuntu.com"):
    try:
        ips = sorted({row[4][0] for row in socket.getaddrinfo(host, 443)})
        print(f"DNS OK   {host}: {', '.join(ips[:4])}")
    except Exception as exc:
        print(f"DNS FAIL {host}: {exc}")
try:
    s = socket.create_connection(("repo.waydro.id", 443), 8)
    print("TCP OK    repo.waydro.id:443")
    s.close()
except Exception as exc:
    print(f"TCP FAIL  repo.waydro.id:443: {exc}")
PY
'

echo
echo "=== Waydroid / Android ==="
if sudo docker exec "$container" command -v waydroid >/dev/null 2>&1; then
  sudo docker exec "$container" waydroid status || true
  if sudo docker exec "$container" waydroid status 2>/dev/null | grep -qi 'RUNNING'; then
    sudo docker exec "$container" waydroid shell -- ip route 2>/dev/null || true
    sudo docker exec "$container" waydroid shell -- getprop net.dns1 2>/dev/null || true
    sudo docker exec "$container" waydroid shell -- ping -c 1 -W 3 1.1.1.1 2>/dev/null || true
    sudo docker exec "$container" waydroid shell -- ping -c 1 -W 3 repo.waydro.id 2>/dev/null || true
  else
    echo "Android 尚未运行；先在 Ubuntu 中启动 Waydroid 后再执行本脚本。"
  fi
else
  echo "当前镜像未安装 Waydroid。"
fi
