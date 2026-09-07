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
  echo ""
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
  [[ "${answer_store:-Y}" =~ ^[Yy]$ ]] && install_store=true || install_store=false
  [[ "${answer_chrome:-Y}" =~ ^[Yy]$ ]] && install_chrome=true || install_chrome=false
  desktop_image=fnos-ubuntu26-gnome-hdmi:wayland-zh-custom

  awk \
    -v password="$desktop_password" \
    -v store="$install_store" \
    -v chrome="$install_chrome" \
    -v image="$desktop_image" '
      /^DESKTOP_PASSWORD=/ {print "DESKTOP_PASSWORD=" password; next}
      /^REMOTE_LOGIN_PASSWORD=/ {print "REMOTE_LOGIN_PASSWORD=" password; next}
      /^INSTALL_APP_STORE=/ {print "INSTALL_APP_STORE=" store; next}
      /^INSTALL_GOOGLE_CHROME=/ {print "INSTALL_GOOGLE_CHROME=" chrome; next}
      /^DESKTOP_IMAGE=/ {print "DESKTOP_IMAGE=" image; next}
      {print}
    ' .env.example >.env
  chmod 0600 .env
else
  custom_image="$(awk -F= '$1 == "CUSTOM_DESKTOP_IMAGE" {print $2; exit}' .env)"
  custom_image="${custom_image:-fnos-ubuntu26-gnome-hdmi:wayland-zh-custom}"
  tmp_env="$(mktemp "$project_dir/.env.XXXXXX")"
  awk -v image="$custom_image" '
    /^DESKTOP_IMAGE=/ {print "DESKTOP_IMAGE=" image; found=1; next}
    {print}
    END {if (!found) print "DESKTOP_IMAGE=" image}
  ' .env >"$tmp_env"
  mv "$tmp_env" .env
  chmod 0600 .env
fi

chmod +x preflight.sh prepare-guacamole.sh setup-storage.sh create-rdp-file.sh
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
  sudo docker compose -f compose.yaml -f compose.extras.yaml \
    build ubuntu26-gnome-hdmi
fi

for image in guacamole/guacd:1.6.0 guacamole/guacamole:1.6.0; do
  if ! sudo docker image inspect "$image" >/dev/null 2>&1; then
    sudo docker pull "$image"
  fi
done

./prepare-guacamole.sh
sudo docker compose config --quiet
sudo docker compose --profile web up -d

server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
  {for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}
')"
server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
server_ip="${server_ip:-fnOS-IP}"
if [[ "$server_ip" != "fnOS-IP" ]]; then
  desktop_user="$(awk -F= '$1 == "DESKTOP_USER" {print $2; exit}' .env)"
  desktop_user="${desktop_user:-ubuntu}"
  ./create-rdp-file.sh "$server_ip" 3391 \
    "fnos-remote-login-$server_ip.rdp" "$desktop_user"
fi
echo
echo "部署完成："
echo "  Windows/macOS 同屏桌面：$server_ip:3389"
echo "  GNOME 独立远程登录：   $server_ip:3391"
echo "  网页桌面：             http://$server_ip:8080/"
echo "  NAS 文件：Ubuntu 主文件夹中的 NAS-vol1、NAS-vol2……"
if [[ "$server_ip" != "fnOS-IP" ]]; then
  echo "  3391 专用连接文件：     $project_dir/fnos-remote-login-$server_ip.rdp"
  echo "  请下载该 .rdp 文件后双击连接；不要直接新建 3391 设备。"
fi
