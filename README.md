# fnOS Ubuntu 26.04 GNOME Wayland 桌面

这套配置在 fnOS 的 Docker 中运行中文 Ubuntu GNOME Wayland，支持 HDMI、
音频、RDP 和浏览器访问。Docker 本来就与 fnOS 共用 Linux 内核，不会像
虚拟机一样另起一个内核。

## 端口与会话

| 端口 | 用途 | 是否与 HDMI 同一画面 |
| --- | --- | --- |
| `3389/tcp` | GNOME Desktop Sharing（Windows/macOS 默认入口） | 是，镜像当前 HDMI Wayland 会话 |
| `3390/tcp` | GNOME Desktop Sharing（备用入口） | 是，与 3389 完全相同 |
| `3391/tcp` | GNOME Remote Login | 否，登录独立的 Wayland 会话 |
| `8080/tcp` | Apache Guacamole 1.6.0 HTML5 网页 | 是，它在容器内连接 `3390` |

Ubuntu 26.04 当前的 `grdctl` 没有 VNC 子命令，因此 noVNC 无法直接连接
GNOME Wayland。Guacamole 使用 RDP 桥接到当前 HDMI 桌面共享服务。

## 首次部署

```bash
cd /vol1/1000/docker/ubuntuhdmi
chmod +x preflight.sh prepare-guacamole.sh
sudo ./preflight.sh
cp .env.example .env
vi .env
sudo docker compose up -d ubuntu26-gnome-hdmi
```

`.env` 中必须替换 `DESKTOP_PASSWORD`，并保持 `REMOTE_MODE=both`。
容器每次启动都会直接配置并开启系统级 GNOME Remote Login（宿主机 3391）和
用户级 Desktop Sharing（宿主机 3389/3390），无需进入“设置”点“解锁”，也不
依赖 Polkit 弹窗。Windows App 请连接 3389；它和网页端均操作 HDMI 同一桌面。
`AUTO_LOGIN=true` 让无人值守启动后自动建立供 HDMI、3390 和网页端共同使用的
Wayland 桌面；共享脚本同时关闭该桌面的自动锁屏和空闲挂起。

3391 的 Remote Login 会创建独立的 Wayland 登录会话，并不镜像 HDMI 当前画面。
GNOME 不允许同一账号同时保持本地和远程两次登录，因此 `ubuntu` 已经在 HDMI
自动登录时应使用 3389、3390 或网页；若要测试 3391，请先从 HDMI 桌面注销该账号。

启用网页端：

```bash
./prepare-guacamole.sh
sudo docker compose --profile web up -d
```

浏览器打开 `http://fnOS-IP:8080/`，用 `.env` 中的桌面账号和密码登录。
当前的 XML 认证配置只适合可信局域网，不应直接暴露到公网；公网使用前
应添加 HTTPS/VPN，并迁移到 Guacamole 数据库认证。

## 可选：应用商店与 Chrome

基础镜像保持精简。需要额外软件时，在 `.env` 中选择：

```ini
INSTALL_APP_STORE=true
INSTALL_GOOGLE_CHROME=true
CUSTOM_DESKTOP_IMAGE=fnos-ubuntu26-gnome-hdmi:wayland-zh-apps
DESKTOP_IMAGE=fnos-ubuntu26-gnome-hdmi:wayland-zh-apps
```

`INSTALL_APP_STORE` 安装原生 GNOME Software（“软件”应用），不会在容器中引入
依赖复杂挂载的 Snap 商店。`INSTALL_GOOGLE_CHROME` 仅支持 amd64，默认下载 Google
官方 stable `.deb`；国内网络可把 `CHROME_DEB_URL` 改为可信镜像地址。

从已经导入本机的基础镜像派生，不会重新拉取 `ubuntu:26.04`：

```bash
sudo docker compose -f compose.yaml -f compose.extras.yaml build ubuntu26-gnome-hdmi
sudo docker compose -f compose.yaml -f compose.extras.yaml --profile web up -d
```

构建完成后，`DESKTOP_IMAGE` 决定日常 `docker compose up` 使用基础镜像还是派生
镜像；因此切换到带软件版本后不必一直附加第二个 Compose 文件。

若两项都不要，继续只使用 `compose.yaml`。若只需要其中一项，将另一项设为
`false` 后重新构建派生镜像。

## 无显示器重启

Wayland 的同屏镜像需要 DRM 始终存在一个输出。可用 HDMI 欺骗器，或在 fnOS
宿主机内核参数中强制输出：

```text
video=HDMI-A-1:1920x1080@60e
```

修改 `/etc/default/grub` 后执行 `sudo update-grub`。不要重复执行会不断插入
参数的 `sed` 命令；用 `cat /proc/cmdline` 确认只有一个 `video=`。再用：

```bash
for p in /sys/class/drm/card*-*/status; do echo -n "$p: "; cat "$p"; done
```

确认 `HDMI-A-1` 即使无实体显示器也是 `connected`。
注意：当前 fnOS 内核曾对该参数记录 `User-defined mode not supported`，
所以 `connected` 不等于指定的 1920×1080@60 模式已真正生效。如果收窄
GPU 设备后热拔插仍能复现卡死，下一步应测试有效 EDID 固件或实体 HDMI
欺骗器，而不是继续叠加 `video=` 参数。

如果 `card0-HDMI-A-1/modes` 最高只有 `1024x768`，单独的 `video=` 无法让
GNOME 选择不存在的模式。项目附带标准 1080p60 EDID 安装脚本；它会验证 EDID、
备份 GRUB、更新 initramfs，但不会自动重启：

```bash
sudo ./install-fhd-edid.sh HDMI-A-1
sudo reboot
cat /sys/class/drm/card0-HDMI-A-1/modes
```

只有当输出中出现 `1920x1080` 后，同屏 RDP 才可能以原生 1080p 工作。此操作
修改的是 fnOS 宿主机启动配置；建议保留脚本打印的 GRUB 备份路径。

## 内存与关机安全

GNOME、GDM、PipeWire 和文件索引是主要内存来源。`MEMORY_LIMIT=4g` 是上限，
不是预分配；`shm_size` 和 tmpfs 的 size 也只是上限。查看实际用量：

```bash
sudo docker stats --no-stream ubuntu26-gnome-hdmi ubuntu26-guacamole ubuntu26-guacd
```

Compose 已使用 `cgroup: private`，并移除了宿主 `/sys/fs/cgroup` 的可写映射。
容器内 logind 也会忽略物理电源键、休眠和盒盖动作。

该 fnOS 使用带外补丁的 `i915-sriov-dkms`，`card1`–`card4` 是 SR-IOV VF。
旧配置的 `privileged: true` 和整目录 `/dev/dri` 会让 Mutter 尝试打开所有
VF，并产生 `No suitable mode setting backend` 和 EBADF 错误。当前配置已改为
非特权容器，只允许物理 PF `card0` 和 `renderD128`，因此仍能使用 HDMI，
但 GNOME 不再枚举四个 VF。

fnOS 的 AppArmor 默认禁止非特权容器重新挂载 cgroup。因此桌面容器仅对
AppArmor 使用 `unconfined`，并只添加 systemd/KMS 所需的三个 capability；
这不等于 `privileged`，也没有恢复对其他 GPU 节点的访问。

普通停止测试：

```bash
time sudo docker compose --profile web stop
```

若 20 秒内没有停止，先查看 `docker compose logs`，不要直接强制关闭 fnOS。

### 物理 HDMI 热插拔测试

当前已验证无物理 HDMI 时可正常启动 Wayland，容器可在约 3 秒内
停止。物理 HDMI-A-3 的热插拔需要现场测试。测试前运行：

```bash
sudo ./hdmi-diagnostic.sh start
```

在 10 分钟内完成“插入 HDMI → 确认画面 → 拔出 HDMI”，然后：

```bash
time sudo docker compose stop ubuntu26-gnome-hdmi
sudo ./hdmi-diagnostic.sh stop
sudo docker compose up -d ubuntu26-gnome-hdmi
```

采集会在 10 分钟后自动停止，结果在 `.hdmi-diagnostics/latest/`。如果
`docker compose stop` 卡住，不要立即重启；在第二个 SSH 窗口执行：

```bash
sudo ./hdmi-diagnostic.sh snapshot
```

它会记录连接器状态、DRM 占用者、不可中断的 `D` 状态进程、内核栈和
i915 日志。

## 中国网络/新 fnOS 离线部署

在能访问 Ubuntu 和 Docker Hub 的 amd64 主机构建：

```bash
docker buildx build --platform linux/amd64 \
  -t fnos-ubuntu26-gnome-hdmi:wayland-zh --load .
docker pull --platform linux/amd64 guacamole/guacamole:1.6.0
docker pull --platform linux/amd64 guacamole/guacd:1.6.0

docker save fnos-ubuntu26-gnome-hdmi:wayland-zh | gzip > desktop-amd64.tar.gz
docker save guacamole/guacamole:1.6.0 guacamole/guacd:1.6.0 | \
  gzip > guacamole-1.6.0-amd64.tar.gz
```

将项目文件和两个压缩包复制到新 fnOS：

```bash
sha256sum -c SHA256SUMS
gzip -dc desktop-amd64.tar.gz | sudo docker load
gzip -dc guacamole-1.6.0-amd64.tar.gz | sudo docker load
cp .env.example .env
vi .env
./prepare-guacamole.sh
sudo docker compose --profile web up -d
```

## 检查

```bash
sudo docker exec ubuntu26-gnome-hdmi loginctl list-sessions
sudo docker exec ubuntu26-gnome-hdmi systemctl status \
  fnos-remote-login.service fnos-desktop-sharing.service \
  gnome-remote-desktop.service --no-pager
sudo docker exec ubuntu26-gnome-hdmi bash -lc \
  'for p in 3389 3390; do timeout 2 bash -c "</dev/tcp/127.0.0.1/$p" && echo "$p open"; done'
curl -I http://127.0.0.1:8080/
```
