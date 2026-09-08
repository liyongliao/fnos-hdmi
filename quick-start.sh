#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

if [[ -f .env ]]; then
  read -r -p "检测到已有 .env。是否保留现有配置并只重新部署？[Y/n] " keep_env
  if [[ ! "${keep_env:-Y}" =~ ^[Yy]$ ]]; then
    backup=".env.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a .env "$backup"
    echo "旧配置已备份为 $backup"
    rm -f .env
  fi
fi

build_custom=true
if [[ ! -f .env ]]; then
  echo
  echo "请输入 Ubuntu 桌面密码（至少 8 位，可用字母、数字和 ._@%+=:-）："
  while true; do
    read -r -s -p "密码：" desktop_password
    echo
    read -r -s -p "再次输入：" password_confirm
    echo
    if [[ "$desktop_password" != "$password_confirm" ]]; then
      echo "两次密码不同，请重新输入。"
      continue
    fi
    if [[ ! "$desktop_password" =~ ^[A-Za-z0-9._@%+=:-]{8,64}$ ]]; then
      echo "密码格式不符合要求，请重新输入。"
      continue
    fi
    break
  done

  read -r -p "安装 GNOME 软件中心？[Y/n] " answer_store
  read -r -p "安装 Google Chrome？[Y/n] " answer_chrome
  read -r -p "安装 Waydroid 安卓运行环境？[y/N] " answer_waydroid
  echo
  echo "Docker privileged 高兼容模式会放宽容器硬件/LXC权限，Waydroid 推荐开启。"
  echo "如果设备有特殊虚拟 GPU/SR-IOV，也可以选择关闭后使用精细权限模式。"
  read -r -p "开启 privileged 高兼容模式？[Y/n] " answer_privileged

  [[ "${answer_store:-Y}" =~ ^[Yy]$ ]] && install_store=true || install_store=false
  [[ "${answer_chrome:-Y}" =~ ^[Yy]$ ]] && install_chrome=true || install_chrome=false
  [[ "${answer_waydroid:-N}" =~ ^[Yy]$ ]] && install_waydroid=true || install_waydroid=false
  [[ "${answer_privileged:-Y}" =~ ^[Yy]$ ]] && privileged_mode=true || privileged_mode=false
  desktop_image=fnos-ubuntu26-gnome-hdmi:wayland-zh-custom

  awk \
    -v password="$desktop_password" \
    -v store="$install_store" \
    -v chrome="$install_chrome" \
    -v waydroid="$install_waydroid" \
    -v privileged="$privileged_mode" \
    -v image="$desktop_image" '
      /^DESKTOP_PASSWORD=/ {print "DESKTOP_PASSWORD=" password; next}
      /^REMOTE_LOGIN_PASSWORD=/ {print "REMOTE_LOGIN_PASSWORD=" password; next}
      /^INSTALL_APP_STORE=/ {print "INSTALL_APP_STORE=" store; next}
      /^INSTALL_GOOGLE_CHROME=/ {print "INSTALL_GOOGLE_CHROME=" chrome; next}
      /^INSTALL_WAYDROID=/ {print "INSTALL_WAYDROID=" waydroid; next}
      /^PRIVILEGED_MODE=/ {print "PRIVILEGED_MODE=" privileged; next}
      /^DESKTOP_IMAGE=/ {print "DESKTOP_IMAGE=" image; next}
      {print}
    ' .env.example >.env
  chmod 0600 .env
else
  custom_image="$(awk -F= '$1 == "CUSTOM_DESKTOP_IMAGE" {print $2; exit}' .env)"
  custom_image="${custom_image:-fnos-ubuntu26-gnome-hdmi:wayland-zh-custom}"
  tmp_env="$(mktemp "$project_dir/.env.XXXXXX")"
  awk -v image="$custom_image" '
    /^DESKTOP_IMAGE=/ {print "DESKTOP_IMAGE=" image; found_image=1; next}
    {print}
    END {
      if (!found_image) print "DESKTOP_IMAGE=" image
    }
  ' .env >"$tmp_env"
  mv "$tmp_env" .env
  chmod 0600 .env

  # Old .env files predate these options. Add compatibility-first defaults
  # without overwriting values already selected by the user.
  grep -q '^PRIVILEGED_MODE=' .env || echo 'PRIVILEGED_MODE=true' >>.env
  grep -q '^LIMIT_GPU_DEVICES=' .env || echo 'LIMIT_GPU_DEVICES=true' >>.env
  grep -q '^BIND_ADDRESS=' .env || echo 'BIND_ADDRESS=0.0.0.0' >>.env
fi

# binderfs uses a dynamically allocated character-device major. Docker needs
# the number in scoped mode; privileged mode ignores the restriction but we
# still record it so switching modes does not require another setup step.
binder_major="$(awk '$2 == "binder" {print $1; exit}' /proc/devices)"
if [[ -n "$binder_major" ]]; then
  tmp_env="$(mktemp "$project_dir/.env.XXXXXX")"
  awk -v major="$binder_major" '
    /^BINDER_DEVICE_MAJOR=/ {print "BINDER_DEVICE_MAJOR=" major; found=1; next}
    {print}
    END {if (!found) print "BINDER_DEVICE_MAJOR=" major}
  ' .env >"$tmp_env"
  mv "$tmp_env" .env
  chmod 0600 .env
else
  echo "警告：fnOS 内核没有注册 binder 驱动，Waydroid 将无法运行。" >&2
fi

chmod +x preflight.sh prepare-guacamole.sh setup-storage.sh create-rdp-file.sh prepare-waydroid-runtime.sh
./preflight.sh
./setup-storage.sh

base_image=fnos-ubuntu26-gnome-hdmi:wayland-zh
if ! sudo docker image inspect "$base_image" >/dev/null 2>&1; then
  archive=""
  for candidate in \
    fnos-ubuntu26-gnome-wayland-zh-amd64.tar.gz \
    fnos-ubuntu26-gnome-hdmi-wayland-zh-amd64.tar.gz; do
    if [[ -f "$candidate" ]]; then
      archive="$candidate"
      break
    fi
  done
  if [[ -n "$archive" ]]; then
    echo "正在导入本地桌面镜像：$archive"
    sudo docker load -i "$archive"
  else
    echo "未发现本地镜像，开始联网构建 Ubuntu 桌面……"
    sudo docker build -t "$base_image" .
  fi
fi

if [[ "$build_custom" == true ]]; then
  sudo docker compose -f compose.yaml -f compose.extras.yaml build ubuntu26-gnome-hdmi
fi

for image in guacamole/guacd:1.6.0 guacamole/guacamole:1.6.0; do
  if ! sudo docker image inspect "$image" >/dev/null 2>&1; then
    sudo docker pull "$image"
  fi
done

./prepare-guacamole.sh
sudo docker compose config --quiet

waydroid_requested="$(awk -F= '$1 == "INSTALL_WAYDROID" {print tolower($2); exit}' .env)"
waydroid_requested="${waydroid_requested:-false}"
privileged_mode="$(awk -F= '$1 == "PRIVILEGED_MODE" {print tolower($2); exit}' .env)"
privileged_mode="${privileged_mode:-true}"

# Migrate the old two-stage host-loop implementation if this project created
# it. New installs never create this host service.
legacy_unit=/etc/systemd/system/fnos-waydroid-desktop.service
if sudo test -f "$legacy_unit" && sudo grep -q '^# Managed by setup-waydroid.py' "$legacy_unit"; then
  echo "检测到旧版 Waydroid 双模式开机服务，正在迁移到单一运行模式……"
  sudo systemctl disable --now fnos-waydroid-desktop.service 2>/dev/null || true
  sudo rm -f "$legacy_unit"
  sudo systemctl daemon-reload

  waydroid_data_value="$(awk -F= '$1 == "WAYDROID_DATA" {print $2; exit}' .env)"
  waydroid_data_value="${waydroid_data_value:-./waydroid-data}"
  if [[ "$waydroid_data_value" = /* ]]; then
    waydroid_data_dir="$waydroid_data_value"
  else
    waydroid_data_dir="$project_dir/${waydroid_data_value#./}"
  fi
  for android_img in "$waydroid_data_dir/images/system.img" "$waydroid_data_dir/images/vendor.img"; do
    [[ -e "$android_img" ]] || continue
    while read -r loopdev readonly; do
      [[ -n "${loopdev:-}" ]] || continue
      if [[ "${readonly:-0}" == "1" ]]; then
        sudo losetup -d "$loopdev" 2>/dev/null || true
      fi
    done < <(sudo losetup --associated "$(readlink -f "$android_img")" --noheadings --output NAME,RO 2>/dev/null || true)
  done
fi

# One Docker runtime from the first boot onward. Waydroid downloads and mounts
# Android images inside Ubuntu; no later Docker recreation is required.
sudo docker compose --profile web up -d --force-recreate

# Check Ubuntu container outbound connectivity. Do not abort deployment on a
# temporary network problem; print a clear warning for troubleshooting.
if sudo docker exec ubuntu26-gnome-hdmi python3 - <<'PY' >/dev/null 2>&1
import socket
socket.getaddrinfo('repo.waydro.id', 443)
s = socket.create_connection(('repo.waydro.id', 443), 8)
s.close()
PY
then
  network_status="正常"
else
  network_status="异常（请检查 fnOS 默认网关/DNS/Docker bridge）"
fi

server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
  {for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}
')"
server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
server_ip="${server_ip:-fnOS-IP}"
if [[ "$server_ip" != "fnOS-IP" ]]; then
  desktop_user="$(awk -F= '$1 == "DESKTOP_USER" {print $2; exit}' .env)"
  desktop_user="${desktop_user:-ubuntu}"
  ./create-rdp-file.sh "$server_ip" 3391 "fnos-remote-login-$server_ip.rdp" "$desktop_user"
fi

echo
echo "部署完成："
echo "  privileged 高兼容模式：$privileged_mode"
echo "  Ubuntu/Docker 外网：    $network_status"
echo "  Windows/macOS 同屏桌面：$server_ip:3389"
echo "  GNOME 独立远程登录：   $server_ip:3391"
echo "  网页桌面：             http://$server_ip:8080/"
echo "  NAS 文件：Ubuntu 主文件夹中的 NAS-vol1、NAS-vol2……"
if [[ "$server_ip" != "fnOS-IP" ]]; then
  echo "  3391 专用连接文件：     $project_dir/fnos-remote-login-$server_ip.rdp"
fi

if [[ "$waydroid_requested" == "true" ]]; then
  echo
  echo "Waydroid 已安装为单一运行模式："
  echo "  1. 直接进入 Ubuntu 桌面并打开 Waydroid。"
  echo "  2. 首次选择 Vanilla/GAPPS，Android 镜像会保存到 WAYDROID_DATA。"
  echo "  3. 下载完成后当前容器直接挂载并启动 Android。"
  echo "  4. 不再需要 setup-waydroid.py，也不会为了 Waydroid 重建 GNOME 容器。"
fi
