# Waydroid 单一运行模式

目标：Ubuntu GNOME 容器从第一次启动起就具备 Waydroid 所需的 Binder、LXC、网络和 loop 能力。用户只需要在 Ubuntu 桌面内初始化 Android 镜像，下载完成后直接启动；不再由 fnOS 主机预分配 `system.img` / `vendor.img` loop 设备，也不再因为启用 Waydroid 重建 GNOME 容器。

## 运行模型

Waydroid 上游本身直接把 `/var/lib/waydroid/images/system.img` 和 `vendor.img` 交给 `mount`。util-linux 对普通镜像文件挂载时会使用 Linux loop 子系统，因此 Ubuntu 容器只要从第一次启动起就具备对应能力即可。

```text
fnOS
  └─ Docker bridge
      └─ Ubuntu 26.04 GNOME
          ├─ HDMI / RDP / Web
          └─ Waydroid
              ├─ 下载 system.img/vendor.img
              ├─ 容器内自动 loop mount
              ├─ waydroid0 bridge + NAT
              └─ Android / GAPPS
```

Android 外网路径为：

```text
Android -> waydroid0 -> Ubuntu 容器 -> Docker bridge -> fnOS -> LAN/Internet
```

项目设置 `net.ipv4.ip_forward=1`，Waydroid 自己维护 `waydroid0` 的 dnsmasq/NAT，Docker bridge 再负责容器到 fnOS 外部网络的 NAT。

## privileged 由用户决定

`.env`：

```ini
PRIVILEGED_MODE=true
```

`true` 是高兼容模式，优先保证 Waydroid、LXC、loop 和硬件功能可用；`false` 则使用项目内配置的 capability 与 device cgroup 规则。

安装向导会直接询问是否开启 privileged。项目不再把 `privileged: true` 当成错误。

在有多个 i915 SR-IOV VF 的 fnOS 设备上，即使开启 privileged，默认仍设置：

```ini
LIMIT_GPU_DEVICES=true
```

容器启动时会只在自己的 `/dev/dri` 中保留 `card0` 和 `renderD128`，避免 GNOME/Mutter 枚举虚拟 GPU。这个动作不会删除或修改 fnOS 主机设备。确实需要其他 GPU 时改成 `false`。

## 新安装

```bash
./quick-start.sh
```

向导选择安装 Waydroid 后：

1. Ubuntu/GNOME 正常启动；
2. 打开 Waydroid；
3. 选择 Vanilla 或 GAPPS；
4. Waydroid 在 `/var/lib/waydroid` 持久化目录下载 Android 镜像；
5. 第一次启动 Android 时，容器内部自动准备 fnOS 兼容 overlay；
6. Waydroid 原生 mount 镜像并启动 LXC；
7. 不需要回 fnOS SSH 执行第二阶段命令。

## 从旧双模式迁移

旧版本如果已经执行过：

```bash
sudo python3 setup-waydroid.py --install-autostart
```

新版本运行 `./quick-start.sh` 会自动识别并移除本项目旧的 `fnos-waydroid-desktop.service`，释放旧的只读 host loop。也可以手工执行：

```bash
sudo python3 setup-waydroid.py --migrate
```

迁移时只需要为新 Compose 配置重建一次桌面。以后 Android 镜像安装、升级、启动都不再触发 Docker recreate。

## 外部网络和远程访问

默认：

```ini
BIND_ADDRESS=0.0.0.0
RDP_PORT=3389
DESKTOP_SHARING_PORT=3390
REMOTE_LOGIN_PORT=3391
WEB_PORT=8080
```

这样 RDP 和网页桌面会监听 fnOS 的所有网络接口。若只允许某个 LAN/VPN 地址访问，把 `BIND_ADDRESS` 改成对应 IP。

检查 Ubuntu 与 Android 外网：

```bash
chmod +x network-diagnostic.sh
./network-diagnostic.sh
```

它会检查 fnOS 默认路由、Ubuntu 容器 DNS/TCP 访问，以及 Waydroid 已运行时的 Android 路由和连通性。

## 常用检查

```bash
sudo docker exec ubuntu26-gnome-hdmi bash -lc '
ls -l /dev/loop-control /dev/loop0 /dev/loop1 2>/dev/null || true
cat /proc/devices | grep -E "(^| )loop$"
waydroid status || true
losetup -a | head -20
journalctl -u waydroid-container.service -b --no-pager | tail -100
'
```

正常预期：

- Android 镜像下载后不发生 `docker recreate`；
- HDMI/RDP 桌面不会因为启用 Waydroid 被断开；
- `waydroid status` 能进入 RUNNING；
- `system.img` / `vendor.img` 的 loop 分配由 Ubuntu 容器内自动完成；
- Android 可以通过 Docker bridge 正常访问外部网络；
- 不需要 fnOS 开机服务维护固定 `/dev/loopN` 编号。
