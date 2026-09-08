# 飞牛 fnOS Docker Ubuntu 26.04 中文桌面

让飞牛 NAS 同时成为一台 Ubuntu 桌面电脑：

- HDMI 直接输出 GNOME Wayland 中文桌面和声音
- 没有显示器也能无头启动
- Windows/macOS 使用 RDP 连接
- 手机、平板和电脑使用浏览器访问
- HDMI、3389 和网页端操作同一个真实桌面
- 自动识别并映射 `/vol1`、`/vol2` 等 fnOS 存储卷
- 可选安装 GNOME 软件中心和 Google Chrome

Docker 与 fnOS 共用宿主机 Linux 内核，并不是一台完整虚拟机。

## 先看懂四个端口

| 地址 | 用途 | 看到的画面 |
| --- | --- | --- |
| `fnOS-IP:3389` | 推荐，Windows/macOS RDP | 与 HDMI 完全相同 |
| `fnOS-IP:3390` | 备用 RDP | 与 3389 相同 |
| `fnOS-IP:3391` | GNOME Remote Login（用脚本生成的 `.rdp`） | 新建独立 Wayland 登录会话 |
| `http://fnOS-IP:8080/` | 浏览器桌面 | 与 HDMI 完全相同 |

日常使用请选择 **3389 或网页端**。它们共享当前 HDMI 桌面，窗口、鼠标和
分辨率都会同步。3391 是真正的“远程登录”，不是桌面镜像。

## 一键安装（新手推荐）

### 1. 准备条件

- x86-64/amd64 飞牛 NAS
- Intel 核显在 fnOS 中对应 `/dev/dri/card0` 和 `renderD128`
- 已安装 Docker，并能通过 SSH 登录 fnOS
- 已把本项目完整复制到 NAS，例如 `/vol1/1000/docker/ubuntuhdmi`

进入项目目录：

```bash
cd /vol1/1000/docker/ubuntuhdmi
chmod +x quick-start.sh
./quick-start.sh
```

不要使用 `sudo ./quick-start.sh`。脚本会在需要操作 Docker 时自行调用 sudo。

安装向导只会询问四件事：

1. Ubuntu 桌面密码
2. 是否安装软件中心
3. 是否安装 Google Chrome
4. 是否安装 Waydroid 安卓运行环境（默认不安装）

随后会自动完成硬件检查、创建 `.env`、映射 NAS 存储、准备网页端并启动容器。
第一次联网构建需要下载 Ubuntu 软件包，时间取决于网络速度。安装结束还会在项目
目录中生成一个名为 `fnos-remote-login-飞牛IP.rdp` 的 3391 专用连接文件。

### 2. 打开桌面

假设飞牛地址是 `192.168.31.100`：

- Windows/macOS 远程桌面：`192.168.31.100:3389`
- 浏览器：`http://192.168.31.100:8080/`
- HDMI：直接连接 NAS 的物理 HDMI 接口

账号默认为 `ubuntu`，密码是安装向导中设置的密码。

浏览器若提示不安全，是因为当前使用局域网 HTTP。不要把 3389、3390、3391、
8080 直接映射到公网；公网访问请使用 VPN 或配置 HTTPS。

要使用真正的独立远程登录，请把安装向导生成的 `.rdp` 文件下载到客户端后双击。
Windows 使用系统自带的 `mstsc` 打开；macOS 使用 Windows App 打开。不要在客户端
中直接新建 `IP:3391` 设备，否则客户端可能漏掉 GNOME 必需的 RDP Server
Redirection 参数，表现为黑屏、只有鼠标、登录后无法进入桌面或凭据超时。

## NAS 硬盘在哪里

fnOS 已经把硬盘挂载到了 `/vol1`、`/vol2`、`/vol3` 等目录。容器不应该再次
挂载这些块设备，否则同一个文件系统被重复挂载，可能造成数据风险。

项目中的 `setup-storage.sh` 会根据 `.env` 中的 `DESKTOP_UID` 自动检测该用户在
所有 fnOS 存储卷中的目录，并以普通目录映射到：

```text
/vol1/1000  -> /mnt/fnos/vol1 -> Ubuntu 主文件夹/NAS-vol1
/vol2/1000  -> /mnt/fnos/vol2 -> Ubuntu 主文件夹/NAS-vol2
/vol3/1000  -> /mnt/fnos/vol3 -> Ubuntu 主文件夹/NAS-vol3
```

在 Ubuntu 中打开“文件”，进入主文件夹，直接点击 `NAS-vol1`、`NAS-vol2` 即可。

新增或移除 fnOS 存储卷后执行：

```bash
cd /vol1/1000/docker/ubuntuhdmi
./setup-storage.sh
sudo docker compose up -d --force-recreate
```

默认允许读写。只希望 Ubuntu 读取 NAS 文件时，在 `.env` 中设置：

```ini
NAS_STORAGE_MODE=ro
```

### 为什么以前会出现 `/dev/dm-0 does not exist`

容器共享宿主机内核，因此能在 sysfs/udev 中“看见”fnOS 的 LVM 设备信息；但出于
安全考虑，Docker 没有把宿主机 `/dev/dm-*` 块设备交给容器。Ubuntu 文件管理器
以前会显示这些无法访问的假入口，点击后就会出现：

```text
Error mounting /dev/dm-0 ... special device /dev/dm-0 does not exist
```

当前配置默认禁止容器内 udisks 二次管理宿主块设备，并改用 Docker 目录映射。
只映射当前 fnOS 用户自己的数字目录，不暴露卷根目录中的 `@appdata`、回收站等
系统数据。由于 fnOS 使用专用 `trimacl`，容器再通过 bindfs 提供 Ubuntu 可读写的
权限视图；它不会修改原目录的属主、模式或 ACL。这是预期修复，不要把
`/dev/dm-0` 手工加入 `devices:`。

## 3389 与 3391 有什么区别

### 3389：推荐的同屏桌面

3389 是 GNOME Desktop Sharing。它共享自动登录后已经运行的 Ubuntu Wayland
桌面，因此 HDMI、Windows 和网页端看到的是同一画面，也能同时访问同一份桌面文件。

### 3391：真正的独立远程登录

3391 连接 GNOME 系统级 Remote Login。RDP 首先使用 `.env` 中的
`REMOTE_LOGIN_USER` 和 `REMOTE_LOGIN_PASSWORD` 验证，然后进入 GDM 登录流程。

```ini
REMOTE_LOGIN_USER=ubuntu
REMOTE_LOGIN_PASSWORD=你的密码
```

#### 第一次连接 3391

安装脚本会自动生成专用连接文件。也可以随时手工生成：

```bash
cd /vol1/1000/docker/ubuntuhdmi
./create-rdp-file.sh 192.168.31.100
```

生成的 `fnos-remote-login.rdp` 必须下载到要操作的 Windows 或 Mac：

- Windows：双击文件，用系统自带的“远程桌面连接”打开。
- macOS：双击文件，用 Windows App 打开；也可以在 Windows App 中选择导入 RDP 文件。
- 首次出现自签名证书提示时，核对地址确实是自己的 fnOS，然后选择继续。

该文件包含 `use redirection server name:i:1`。GNOME Remote Login 会先把客户端重定向
到 GDM 登录页，登录后再重定向到用户 Wayland 会话；普通的手工连接项不一定启用
该能力。连接文件不保存密码，可以安全地复制给自己的其他设备，但不要公开
`.env`。

#### 为什么需要输入两次密码

这是 GNOME Remote Login 的正常安全流程：

1. Windows App/mstsc 弹出的第一次凭据框，使用
   `REMOTE_LOGIN_USER` 和 `REMOTE_LOGIN_PASSWORD`，作用是进入系统登录屏幕。
2. 看到 Ubuntu/GDM 登录界面后，再选择 `ubuntu` 并输入 `DESKTOP_PASSWORD`，作用是
   真正登录 Linux 用户桌面。

默认向导会把两处密码设置成相同值，所以输入同一个密码两次即可。第二次认证不能
自动跳过；如果只希望连接已经登录的真实 HDMI 桌面，请使用 3389。

注意：Linux 不允许同一账号同时占用两个图形登录会话。默认 `AUTO_LOGIN=true`
时，`ubuntu` 已用于 HDMI 桌面。如果要使用同一个 `ubuntu` 账号测试 3391，请先
在 HDMI/3389 桌面中选择“注销”，不要只关闭远程窗口。

如果主要需求是独立远程登录，可以在 `.env` 中改为：

```ini
REMOTE_MODE=login
AUTO_LOGIN=false
```

然后执行：

```bash
sudo docker compose up -d --force-recreate
```

此模式会停用同屏共享，3391 成为主要入口。若需要 HDMI、网页和 Windows 共用
一套正在运行的桌面，请保持 `REMOTE_MODE=both`，日常连接 3389。

## 可选：软件中心与 Chrome

编辑 `.env`：

```ini
INSTALL_APP_STORE=true
INSTALL_GOOGLE_CHROME=true
DESKTOP_IMAGE=fnos-ubuntu26-gnome-hdmi:wayland-zh-custom
```

构建并切换到带应用的派生镜像：

```bash
sudo docker compose -f compose.yaml -f compose.extras.yaml \
  build ubuntu26-gnome-hdmi
sudo docker compose --profile web up -d --force-recreate
```

## 可选：Waydroid 安卓运行环境

默认桌面配置只安装 Waydroid。**首次下载 Android 镜像后，还需要在飞牛 SSH
执行下面的启用命令**，不能只在 Ubuntu 内反复点击启动。
不要开启 `privileged` 或映射整个 `/dev`。

Waydroid 本身也是一个基于 LXC 的容器。把它安装到本项目，相当于在 Docker 桌面
容器内再运行一层 Android 容器。项目不会重新启用 `privileged: true`，启用时会增加：

- fnOS Binder 字符设备对应的精确 cgroup 规则；
- 容器私有网络命名空间内创建 `waydroid0` 网桥所需的 `NET_ADMIN`；
- `/var/lib/waydroid` 持久化目录，避免重建桌面后重新下载 Android 镜像。
- 仅关联 Android 镜像的两个只读 loop 设备，以及嵌套 Android 所需的资源权限；
- 飞牛开机服务，重新检测设备编号并启动桌面容器，避免沿用失效的 loop 编号。

新安装时，在 `./quick-start.sh` 询问“安装 Waydroid”时输入 `y`，随后完成下方初始化步骤。

已有配置请编辑 `.env`：

```ini
INSTALL_WAYDROID=true
WAYDROID_DISTRO=resolute
WAYDROID_DATA=./waydroid-data
```

然后构建派生镜像并重建桌面容器：

```bash
./quick-start.sh
```

`quick-start.sh` 会从 `/proc/devices` 自动检测本机 Binder 主设备号，并写入
`BINDER_DEVICE_MAJOR`。不要照抄其他机器的数字，也不要用 `c *:* rmw` 放开全部
字符设备。

进入 Ubuntu 后从应用菜单启动 Waydroid，按需选择 Vanilla 或 GAPPS 并等待下载完成。
返回**飞牛 SSH**，在本项目目录执行（会短暂断开桌面连接）：

```bash
sudo python3 setup-waydroid.py --install-autostart
```

完成后重新连接 Ubuntu，从应用菜单打开 Waydroid。后续更新项目或 Android 镜像后，
重新执行这条命令。不要用普通 `docker compose up` 重建桌面，否则会遗漏 Waydroid
的附加设备配置；`quick-start.sh` 会识别已启用的开机服务并保留附加配置。
若移动项目目录，应先停用旧路径的 `fnos-waydroid-desktop.service`，不要直接删除数据。

启用后的默认上限为 6GB 内存、8192 个进程/线程（不是预先占满）。需要调整时，
在 `.env` 设置 `WAYDROID_MEMORY_LIMIT` 和 `WAYDROID_PIDS_LIMIT` 后重新运行启用命令。
开机服务负责准备设备和启动 Ubuntu；Android 在你打开 Waydroid 时启动。

排查 Binder 权限时，在 **Ubuntu 桌面终端**执行：

```bash
sudo python3 - <<'PY'
import os
fd = os.open('/dev/binderfs/binder-control', os.O_RDONLY)
os.close(fd)
print('Binder 权限正常')
PY
```

如果仍出现 `Operation not permitted`，确认容器是修改 compose 后重新创建的，而不只是
执行了 `docker compose restart`：

```bash
sudo python3 setup-waydroid.py --install-autostart
```

软件中心使用 GNOME Software 的 Deb/PackageKit 后端，不依赖容器中较难维护的 Snap。
Chrome 默认从 Google 官方地址下载；访问困难时可在 `.env` 中修改
`CHROME_DEB_URL` 为可信的 amd64 `.deb` 地址。

不需要某项时将对应值改为 `false`，然后重新执行构建命令。

## 无显示器启动与 1080p

同屏模式的分辨率由 HDMI 输出模式决定，而不是由 Windows 远程桌面窗口决定。
如果虚拟 HDMI 只提供 1024×768，3389 和网页端也只能显示 1024×768。

检查当前模式：

```bash
cat /sys/class/drm/card0-HDMI-A-1/status
cat /sys/class/drm/card0-HDMI-A-1/modes
```

如果最高只有 `1024x768`，仅设置下面的参数通常不够，因为它没有提供有效 EDID：

```text
video=HDMI-A-1:1920x1080@60e
```

项目附带 1080p60 EDID 安装脚本。它会先校验 EDID、备份 GRUB，再更新 initramfs，
但不会自动重启。请在方便现场恢复 NAS 时执行：

```bash
sudo ./install-fhd-edid.sh HDMI-A-1
sudo reboot
cat /sys/class/drm/card0-HDMI-A-1/modes
```

只有最后一条命令出现 `1920x1080`，同屏远程才会使用 1080p。曾出现过物理 HDMI
热拔插导致 i915 卡住的机器，应先保留 SSH/现场恢复手段，再测试 EDID 和热插拔。

## 手动安装（需要理解配置时使用）

```bash
cd /vol1/1000/docker/ubuntuhdmi
chmod +x preflight.sh prepare-guacamole.sh setup-storage.sh
sudo ./preflight.sh
cp .env.example .env
vi .env
./setup-storage.sh
```

`.env` 中至少要修改：

```ini
DESKTOP_PASSWORD=你自己的密码
REMOTE_LOGIN_PASSWORD=你自己的密码
```

如果本机还没有桌面镜像，联网构建：

```bash
sudo docker build -t fnos-ubuntu26-gnome-hdmi:wayland-zh .
```

如果已有 `fnos-ubuntu26-gnome-wayland-zh-amd64.tar.gz`，可以跳过基础镜像构建：

```bash
sudo docker load -i fnos-ubuntu26-gnome-wayland-zh-amd64.tar.gz
```

无论基础镜像来自构建还是导入，都继续生成带存储支持和可选应用的派生镜像，
然后启动桌面和网页服务：

```bash
sudo docker compose -f compose.yaml -f compose.extras.yaml \
  build ubuntu26-gnome-hdmi
./prepare-guacamole.sh
sudo docker compose --profile web up -d
```

## 日常管理

查看运行状态：

```bash
sudo docker compose --profile web ps
```

查看最近日志：

```bash
sudo docker compose logs --tail=200 ubuntu26-gnome-hdmi
```

重启桌面：

```bash
sudo docker compose restart ubuntu26-gnome-hdmi
```

安全停止全部服务：

```bash
time sudo docker compose --profile web stop
```

更新配置后重新创建：

```bash
sudo docker compose --profile web up -d --force-recreate
```

查看实际内存占用：

```bash
sudo docker stats --no-stream \
  ubuntu26-gnome-hdmi ubuntu26-guacamole ubuntu26-guacd
```

`MEMORY_LIMIT=4g` 是上限，不是预先占用 4GB。

## 快速排错

### 远程桌面完全无法连接

```bash
for port in 3389 3390 3391 8080; do
  timeout 2 bash -c "</dev/tcp/127.0.0.1/$port" \
    && echo "$port open" || echo "$port closed"
done
```

### 检查 3391 是否真的保存了凭据

```bash
sudo docker exec ubuntu26-gnome-hdmi grdctl --system status
```

正常输出应包含：

```text
Status: enabled
Port: 3389
Username: (hidden)
Password: (hidden)
```

若显示 `(empty)`，重新创建容器并查看服务日志：

```bash
sudo docker compose up -d --force-recreate
sudo docker exec ubuntu26-gnome-hdmi journalctl \
  -u fnos-remote-login.service -b --no-pager
```

### 黑屏但有鼠标

3389 黑屏时先检查 Wayland 和共享服务：

```bash
sudo docker exec ubuntu26-gnome-hdmi loginctl list-sessions
sudo docker exec ubuntu26-gnome-hdmi systemctl --no-pager status \
  gdm3 gnome-remote-desktop.service fnos-desktop-sharing.service
```

3391 出现黑屏、只有鼠标、凭据超时，或者登录页正常但进不了桌面时：

1. 删除客户端中手工创建的 3391 设备。
2. 重新运行 `./create-rdp-file.sh fnOS-IP`。
3. 下载并双击新生成的 `.rdp` 文件连接。
4. 依次完成远程登录凭据和 Ubuntu 用户凭据两次认证。

反复失败可能留下临时 GDM 会话。确认没有人在使用 3391 后，可清理这些会话并重启
Remote Login 服务：

```bash
sudo docker exec ubuntu26-gnome-hdmi bash -lc '
loginctl list-users --no-legend |
while read -r uid user _; do
  case "$user" in
    gdm-greeter*) loginctl terminate-user "$uid" ;;
  esac
done
systemctl restart fnos-remote-login.service gnome-remote-desktop.service
'
```

不要在有用户通过 3391 工作时执行这段命令，否则会断开其会话。

### 容器或宿主机关机卡住

不要恢复旧版的 `privileged: true`，也不要把完整 `/dev/dri` 或宿主机可写
`/sys/fs/cgroup` 挂进容器。当前配置只开放物理 PF `card0` 和 `renderD128`，避免
Mutter 枚举 fnOS 的 i915 SR-IOV 虚拟显卡。

物理 HDMI 热插拔测试前可采集诊断：

```bash
sudo ./hdmi-diagnostic.sh start
# 完成插入、显示、拔出测试后
sudo ./hdmi-diagnostic.sh stop
```

结果保存在 `.hdmi-diagnostics/latest/`。

## 迁移到新的 fnOS

1. 复制整个项目目录。
2. 如果要保留 Ubuntu 用户数据，同时复制 `.env` 和 `DESKTOP_HOME` 指向的目录。
3. 运行 `./quick-start.sh`。
4. 当脚本询问是否保留 `.env` 时选择 `Y`。
5. 打开 3389 或 8080 验证桌面。

不要复制 `compose.override.yaml` 到存储布局不同的新 NAS；在新 NAS 上重新运行
`./setup-storage.sh`，脚本会根据实际 `/vol*` 自动生成映射。
