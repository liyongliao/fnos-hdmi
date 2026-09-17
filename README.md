# 飞牛 fnOS Docker Ubuntu 26.04 中文桌面

让飞牛 NAS 同时成为一台可长期使用的 Ubuntu 桌面电脑：

- HDMI 直接输出 GNOME Wayland 中文桌面和声音
- 无显示器也能启动
- Windows/macOS 使用 RDP
- 手机、平板、电脑使用浏览器远程桌面
- HDMI、3389、网页端操作同一个真实桌面
- 自动映射 `/vol1`、`/vol2` 等 fnOS 存储
- 可选 GNOME 软件中心、Google Chrome
- 可选 Waydroid / GAPPS
- Waydroid 为**单一运行模式**：在 Ubuntu 内下载 Android 镜像后直接启动，不再切换 Docker 模式
- Docker `privileged` 由用户自己决定

Docker 与 fnOS 共用宿主机 Linux 内核，不是完整虚拟机。

## 家庭电视桌面模式

本镜像按家庭 NAS/电视桌面设计，默认进行以下处理：

- Polkit 服务继续运行，但容器内所有 Polkit 请求直接允许，不再弹出认证密码框；
- 禁用 APT 定时更新、更新通知、Ubuntu Advantage/版本升级提示；
- 跳过 GNOME 首次欢迎页；
- 禁止 GNOME Online Accounts、Identity 和 GOA 文件卷服务在桌面会话中自动启动；
- 关闭 Ubuntu 技术问题上报、软件使用统计和应用使用记录。

这些设置只发生在 Ubuntu 容器内，不会关闭 fnOS 宿主机的 Polkit 或更新服务。
但桌面容器对 NAS 目录拥有写权限，任何能进入该 Ubuntu 桌面的人都可以无密码执行
Polkit 管理操作；不要把 RDP/Web 端口直接暴露到公网。

APT 自动更新被关闭后，系统不会自动获得安全修复。需要维护时手动执行：

```bash
sudo apt update
sudo apt full-upgrade
```

更新完成后重新启动桌面容器。

## 推荐使用方式

### 一键安装

```bash
cd /vol1/1000/docker/ubuntuhdmi
chmod +x quick-start.sh
./quick-start.sh
```

不要使用 `sudo ./quick-start.sh`，脚本会在需要操作 Docker 时自行调用 sudo。

安装向导会询问：

1. Ubuntu 桌面密码
2. 是否安装 GNOME 软件中心
3. 是否安装 Google Chrome
4. 是否安装 Waydroid
5. 是否开启 Docker `privileged` 高兼容模式

其中 `privileged` 默认建议开启，优先保证桌面硬件、LXC、loop 和 Waydroid 的兼容性；不需要时可以关闭，项目会使用精细 capability/device 规则运行。

## 访问桌面

假设 fnOS 地址是 `192.168.31.100`：

| 地址 | 用途 | 画面 |
| --- | --- | --- |
| `192.168.31.100:3389` | 推荐 RDP | 与 HDMI 同一桌面 |
| `192.168.31.100:3390` | 备用 RDP | 与 3389 相同 |
| `192.168.31.100:3391` | GNOME Remote Login | 独立 Wayland 登录会话 |
| `http://192.168.31.100:8080/` | 浏览器桌面 | 与 HDMI 同一桌面 |

默认账号：

```text
ubuntu
```

密码为安装向导中设置的 `DESKTOP_PASSWORD`。

默认：

```ini
BIND_ADDRESS=0.0.0.0
```

因此 RDP/Web 会监听 fnOS 的所有网络接口。如果只想监听某个局域网或 VPN 地址，把它改成对应 IP。

## privileged：用户自己决定

`.env`：

```ini
PRIVILEGED_MODE=true
```

### 高兼容模式

```ini
PRIVILEGED_MODE=true
```

相当于 Compose 中：

```yaml
privileged: true
```

适合：

- Waydroid / LXC
- loop mount
- 更多 USB/硬件设备
- 需要更接近普通 Linux 电脑的使用体验

### 精细权限模式

```ini
PRIVILEGED_MODE=false
```

项目会使用：

- `SYS_ADMIN`
- `NET_ADMIN`
- `SYS_TTY_CONFIG`
- `SYS_NICE`
- `IPC_LOCK`
- `SYS_RESOURCE`
- `SYS_PTRACE`
- `DAC_READ_SEARCH`
- `BLOCK_SUSPEND`
- `MKNOD`
- Binder device cgroup rule
- loop-control / loop block device rule

两种模式使用同一套 Ubuntu/Waydroid 运行逻辑，不再有“普通模式”和“Waydroid 设备模式”之分。

### 多 GPU / SR-IOV

不同 fnOS 机器的物理显示卡可能是 `card0`，也可能是 `card1`。
`quick-start.sh` 会优先选择拥有已连接 HDMI/DP 接口的 DRM 设备，
并写入 `.env`：

```ini
DRM_CARD_DEVICE=/dev/dri/card1
DRM_RENDER_DEVICE=/dev/dri/renderD128
```

这是宿主机设备名。它们会统一映射成容器内的
`card0/renderD128`，所以不要再手工修改 `compose.yaml`。
只有 `card1` 的机器直接重新执行 `./quick-start.sh` 即可。

即使启用 `privileged`，默认：

```ini
LIMIT_GPU_DEVICES=true
```

容器启动时只在自己的 `/dev/dri` 中保留选中的显示 GPU：

```text
card0
renderD128
```

避免 GNOME/Mutter 枚举 fnOS 的 i915 SR-IOV VF。这个动作只修改容器自己的 `/dev`，不会删除宿主机设备。

确实需要其他 GPU 时：

```ini
LIMIT_GPU_DEVICES=false
```

## Waydroid：只保留一套运行模式

Waydroid 本身是 LXC Android 容器。当前结构：

```text
fnOS
  └─ Docker bridge
      └─ Ubuntu 26.04 GNOME
          ├─ HDMI / RDP / Web
          └─ Waydroid
              ├─ system.img
              ├─ vendor.img
              ├─ loop mount
              ├─ waydroid0
              └─ Android / GAPPS
```

新设备安装流程：

```text
./quick-start.sh
        ↓
Ubuntu GNOME 启动
        ↓
打开 Waydroid
        ↓
选择 Vanilla / GAPPS
        ↓
Waydroid 下载 system.img / vendor.img
        ↓
当前 Ubuntu 容器内直接 loop mount
        ↓
启动 Android
```

**不再需要：**

```bash
sudo python3 setup-waydroid.py --install-autostart
```

也不再需要：

```text
system.img -> fnOS /dev/loop2
vendor.img -> fnOS /dev/loop3
Docker Recreate
Waydroid 设备模式
```

Android 镜像和数据持久化在：

```ini
WAYDROID_DATA=./waydroid-data
```

更详细说明见：

```text
WAYDROID-SINGLE-RUNTIME.md
```

### 从旧双模式迁移

运行最新版：

```bash
./quick-start.sh
```

脚本会自动识别本项目创建的旧：

```text
fnos-waydroid-desktop.service
```

并移除旧的 host-side loop 逻辑。

也可以手工执行：

```bash
sudo python3 setup-waydroid.py --migrate
```

迁移只需要为新 Compose 配置重建一次 Docker；之后 Waydroid 安装、升级、启动都不会再重建 GNOME 容器。

## Waydroid / Android 外网

网络路径：

```text
Android
  ↓
waydroid0
  ↓ NAT
Ubuntu Docker
  ↓ NAT
Docker bridge
  ↓
fnOS
  ↓
局域网 / Internet
```

Compose 已启用：

```yaml
net.ipv4.ip_forward: "1"
```

Waydroid 自己维护 `waydroid0` 的 dnsmasq/NAT，Docker bridge 再负责 Ubuntu 容器到 fnOS 外部网络的 NAT。

一键网络诊断：

```bash
chmod +x network-diagnostic.sh
./network-diagnostic.sh
```

它会检查：

- fnOS 默认路由
- fnOS DNS
- Ubuntu 容器 DNS
- Ubuntu 容器 TCP 外网
- Waydroid 状态
- Android 路由
- Android IP/DNS 连通性

## NAS 存储

fnOS 已经把磁盘挂载到 `/vol1`、`/vol2` 等目录。本项目不会让 Ubuntu 再去重复挂载 fnOS 的块设备，而是把用户目录作为普通目录映射：

```text
/vol1/1000 -> /mnt/fnos/vol1 -> ~/NAS-vol1
/vol2/1000 -> /mnt/fnos/vol2 -> ~/NAS-vol2
```

新增或移除存储卷：

```bash
./setup-storage.sh
sudo docker compose --profile web up -d --force-recreate
```

只读：

```ini
NAS_STORAGE_MODE=ro
```

读写：

```ini
NAS_STORAGE_MODE=rw
```

### 让 Waydroid APP 读取 NAS 照片

不要只手工把 NAS 目录 `mount --bind` 到
`~/.local/share/waydroid/data/media/0`。Android 11 及更新版本的应用通过
`/storage/emulated/0` 存储隔离层访问文件，所以宿主机中看起来挂载成功，
Android APP 内仍可能是空目录。

在 `.env` 中配置一个需要共享的 NAS 目录：

```ini
WAYDROID_MEDIA_SOURCE=/mnt/fnos/vol2/Photos
WAYDROID_MEDIA_TARGET=Pictures/nas
WAYDROID_MEDIA_MODE=ro
WAYDROID_MEDIA_SCAN_INTERVAL=1800
```

然后重建主桌面容器（不会删除 Ubuntu 主目录和 Waydroid 数据）：

```bash
sudo docker compose --profile web up -d --force-recreate
```

随后在 Android APP 中打开：

```text
内部存储 / Pictures / nas
```

- `ro` 是照片库的推荐值，Android APP 可查看但不能修改或删除原片。
- 确实需要 Android APP 写入时才改为 `rw`。
- 变更配置或重启 Waydroid 后，自动服务会重新建立应用可见的挂载，并处理 Android 为每个 APP 创建的独立存储命名空间；不需要再手工执行 `mount`。
- `WAYDROID_MEDIA_SCAN_INTERVAL=1800` 会在 Waydroid 每次启动后请求一次 MediaStore 递归扫描，之后每 30 分钟刷新。改成 `300` 表示 5 分钟；改成 `0` 则禁用自动扫描。MediaProvider 会根据文件元数据跳过未变项，但仍会遍历目录，大型照片库建议使用 `1800`–`21600` 秒。
- 已经在后台运行的 Android 相册 APP 请完全关闭后重新打开。首次扫描大型 NAS 照片库可能需要较长时间。

> 如果扫描时 fnOS 的 `dmesg` 出现 `Medium Error`、`UNC` 或
> `I/O error`，请立即把 `WAYDROID_MEDIA_SCAN_INTERVAL` 改为 `0`，
> 先备份数据并检查硬盘。这是存储设备无法读取数据，不是
> Android 权限问题；反复扫描可能让 I/O 进程进入 `D` 状态并拖慢关机。

关闭共享时，将 `WAYDROID_MEDIA_SOURCE=` 留空并再次重建容器。

## 软件中心和 Chrome

`.env`：

```ini
INSTALL_APP_STORE=true
INSTALL_GOOGLE_CHROME=true
DESKTOP_IMAGE=fnos-ubuntu26-gnome-hdmi:wayland-zh-custom
```

重新运行：

```bash
./quick-start.sh
```

## 资源策略

主 GNOME/Waydroid 桌面默认**不设置 RAM、swap、PID 硬上限**。

这是桌面电脑模式，避免 GNOME + Chrome + Waydroid/GAPPS 因短时高内存/线程使用被 Docker 主动杀掉。

如果确实需要限制：

```bash
sudo docker compose \
  -f compose.yaml \
  -f compose.resource-limits.yaml \
  --profile web \
  up -d --force-recreate
```

默认可选限制：

```text
RAM:       12 GB
RAM+swap:  16 GB
PID:       16384
```

诊断资源：

```bash
chmod +x resource-diagnostic.sh
./resource-diagnostic.sh
```

## HDMI / 1080p

这一步同时适用于：

- 真实显示器；
- HDMI 虚拟显示器/欺骗器；
- 完全不插 HDMI 的无头模式。

### 1. 先确认实际 DRM 设备和 HDMI 接口

不要假定一定是 `card0-HDMI-A-1`。执行：

```bash
for p in /sys/class/drm/card*-*/status; do
  connector="${p%/status}"
  printf '%-24s status=%-12s modes=' "${connector##*/}" "$(cat "$p")"
  paste -sd, "$connector/modes" 2>/dev/null || true
done
```

主板有“内侧 HDMI + 外侧 IO HDMI”时，拔掉和重新插入外侧 HDMI，
对比哪一行在 `connected/disconnected` 之间变化。变化的
`HDMI-A-N` 才是需要配置的接口。仅看到 fnOS 开机 Logo 不代表
Docker 内的 GDM/GNOME 已经获得该 DRM 设备。

也可以用项目脚本列出接口：

```bash
sudo ./install-fhd-edid.sh --list
```

### 2. 三种显示模式

**真实显示器**

如果正确接口已经是 `connected` 且 `modes` 含 `1920x1080`，
不需要修改 GRUB。直接部署即可。

**HDMI 虚拟显示器**

优先让虚拟 HDMI 自己提供 1080p EDID。如果只报告 `1024x768`，
再对它所在的接口安装项目内置 EDID：

```bash
sudo ./install-fhd-edid.sh HDMI-A-1
sudo reboot
```

**完全无头：不插显示器，也不插虚拟 HDMI**

必须让宿主机内核强制启用一个真实存在的 HDMI 接口。
如果 3389/Web 需要镜像这套真实桌面，`.env` 还必须保持：

```ini
AUTO_LOGIN=true
REMOTE_MODE=both
SCREEN_SHARE_MODE=mirror-primary
```

先用 `--list` 确认接口名，然后执行：

```bash
sudo ./install-fhd-edid.sh HDMI-A-1
sudo reboot
```

脚本会自动安装经校验的 1080p60 EDID，并向 GRUB 加入：

```text
drm.edid_firmware=HDMI-A-1:edid/fnos-1920x1080.bin
video=HDMI-A-1:1920x1080@60e
```

其中最后的 `e` 表示即使没有热插拔检测也强制启用输出。
如果无头机器有多个 HDMI，脚本会要求明确传入 `HDMI-A-N`，
不会猜测内侧还是外侧接口。

### 3. 重启后验证

```bash
cat /proc/cmdline
sudo ./install-fhd-edid.sh --list
grep -E '^DRM_(CARD|RENDER)_DEVICE=' .env
sudo docker compose exec ubuntu26-gnome-hdmi loginctl list-sessions
sudo docker compose exec ubuntu26-gnome-hdmi \
  systemctl status fnos-desktop-sharing.service --no-pager
```

只有 `modes` 出现 `1920x1080`，且容器内存在 Ubuntu 用户的
Wayland 会话，HDMI、3389 和 Web 同屏才能正常工作。

### 4. 常见错误

`MISSING /dev/dri/card0` 但机器只有 `card1`：

```bash
./quick-start.sh
grep -E '^DRM_(CARD|RENDER)_DEVICE=' .env
```

新版会自动选择 `card1`。如果需要手动指定，也只改 `.env`：

```ini
DRM_CARD_DEVICE=/dev/dri/card1
DRM_RENDER_DEVICE=/dev/dri/renderD128
```

`Failed to start fnos-desktop-sharing.service`：这通常是二次错误，
表示屏幕/GDM 问题导致 Ubuntu Wayland 用户会话没有出现。
新版会等待最多 90 秒再判定失败。诊断：

```bash
sudo docker compose exec ubuntu26-gnome-hdmi \
  journalctl -b -u gdm3 -u fnos-desktop-sharing.service --no-pager
```

## 3391 独立远程登录

3391 是 GNOME Remote Login，不是 3389 的同屏共享。

生成专用 RDP 文件：

```bash
./create-rdp-file.sh 192.168.31.100
```

Windows 使用 `mstsc` 打开；macOS 使用 Windows App 导入。

如果主要使用独立登录：

```ini
REMOTE_MODE=login
AUTO_LOGIN=false
```

如果 HDMI、网页、Windows 要共享同一个真实桌面：

```ini
REMOTE_MODE=both
AUTO_LOGIN=true
```

日常连接 3389。

## 日常管理

状态：

```bash
sudo docker compose --profile web ps
```

日志：

```bash
sudo docker compose logs --tail=200 ubuntu26-gnome-hdmi
```

重启：

```bash
sudo docker compose restart ubuntu26-gnome-hdmi
```

配置变化后重新创建：

```bash
sudo docker compose --profile web up -d --force-recreate
```

资源：

```bash
sudo docker stats --no-stream \
  ubuntu26-gnome-hdmi ubuntu26-guacamole ubuntu26-guacd
```

Waydroid：

```bash
sudo docker exec ubuntu26-gnome-hdmi bash -lc '
waydroid status || true
losetup -a | head -20
journalctl -u waydroid-container.service -b --no-pager | tail -100
'
```

## 快速排错

### 远程端口

```bash
for port in 3389 3390 3391 8080; do
  timeout 2 bash -c "</dev/tcp/127.0.0.1/$port" \
    && echo "$port open" || echo "$port closed"
done
```

### 资源 / OOM

```bash
./resource-diagnostic.sh
```

### 网络

```bash
./network-diagnostic.sh
```

### HDMI

```bash
sudo ./hdmi-diagnostic.sh start
# 完成测试后
sudo ./hdmi-diagnostic.sh stop
```

## 迁移到新的 fnOS

1. 复制整个项目目录。
2. 若保留 Ubuntu 用户数据，同时复制 `.env` 和 `DESKTOP_HOME` 对应目录。
3. 如果保留 Android，同时复制 `WAYDROID_DATA`。
4. 运行 `./quick-start.sh`。
5. 选择保留现有 `.env`。
6. 打开 HDMI、3389 或 8080 验证。

如果新 NAS 的 `/vol*` 布局不同，重新运行：

```bash
./setup-storage.sh
```

## 关键原则

这个项目优先目标是：**把 fnOS 真正当一台 Ubuntu 桌面电脑使用。**

因此：

- 默认不给主桌面设置过小资源限制；
- Waydroid 不再设计成第二套 Docker 运行模式；
- `privileged` 不再被禁止，由用户自行选择；
- 远程访问和 Android 外网优先保证可用；
- 精细权限模式作为可选方案保留。
