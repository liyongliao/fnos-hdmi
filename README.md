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

即使启用 `privileged`，默认：

```ini
LIMIT_GPU_DEVICES=true
```

容器启动时只在自己的 `/dev/dri` 中保留：

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

检查：

```bash
cat /sys/class/drm/card0-HDMI-A-1/status
cat /sys/class/drm/card0-HDMI-A-1/modes
```

如果显示器/虚拟 HDMI 只报告 `1024x768`，项目附带 1080p60 EDID 安装脚本：

```bash
sudo ./install-fhd-edid.sh HDMI-A-1
sudo reboot
cat /sys/class/drm/card0-HDMI-A-1/modes
```

只有最后出现 `1920x1080`，同屏 RDP/Web 才会使用 1080p。

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
