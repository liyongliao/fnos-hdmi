# Waydroid 单一运行模式（测试分支）

目标：Ubuntu GNOME 容器从第一次启动起就具备 Waydroid 所需的 Binder、LXC、网络和 loop 能力。用户只需要在 Ubuntu 桌面内初始化 Android 镜像，下载完成后直接启动；不再由 fnOS 主机预分配 `system.img`/`vendor.img` loop 设备，也不再重建 GNOME 容器。

## 为什么可以这样做

Waydroid 上游本身直接把 `/var/lib/waydroid/images/system.img` 和 `vendor.img` 交给 `mount`。util-linux 对普通镜像文件挂载时会使用 Linux loop 子系统。因此 Docker 只需要允许 Waydroid 容器访问 loop-control 和 loop block major 7，而不是让 fnOS 先 `losetup` 再把固定 `/dev/loopN` 映射进容器。

本项目仍然：

- 不使用 `privileged: true`；
- 不映射整个 `/dev`；
- 不映射整个 `/dev/dri`；
- 只开放物理 GPU `card0` / `renderD128`；
- fnOS 物理磁盘、NVMe、device-mapper 设备仍不在 Docker device cgroup 白名单内。

新增的块设备范围只有 Linux loop major 7，以及 loop-control `10:237`。

## 新安装流程

```bash
./quick-start.sh
```

向导选择安装 Waydroid 后：

1. Ubuntu/GNOME 正常启动；
2. 打开 Waydroid；
3. 选择 Vanilla 或 GAPPS；
4. Waydroid 在 `/var/lib/waydroid` 持久化目录内下载 Android 镜像；
5. 第一次启动 Android 时，容器内部自动准备兼容 overlay，然后 Waydroid 原生 mount 镜像；
6. 不需要回 fnOS SSH 执行第二阶段命令。

## 从旧双模式迁移

旧版本如果已经运行过：

```bash
sudo python3 setup-waydroid.py --install-autostart
```

更新到本分支后执行：

```bash
sudo python3 setup-waydroid.py --migrate
```

兼容脚本会：

- 删除本项目创建的 `fnos-waydroid-desktop.service`；
- 释放旧版只读 host loop 映射；
- 只重建一次桌面容器以应用新的 loop cgroup 权限。

迁移完成后不再需要 `setup-waydroid.py`。

## 测试

容器启动后检查：

```bash
sudo docker exec ubuntu26-gnome-hdmi bash -lc '
ls -l /dev/loop-control /dev/loop0 /dev/loop1
cat /proc/devices | grep -E "(^| )loop$"
command -v waydroid || true
'
```

Waydroid 初始化后：

```bash
sudo docker exec ubuntu26-gnome-hdmi bash -lc '
waydroid status
losetup -a | head -20
journalctl -u waydroid-container.service -b --no-pager | tail -100
'
```

正常预期：

- Android 镜像下载后不发生 `docker recreate`；
- HDMI/RDP 桌面不会因为启用 Waydroid 被断开；
- `waydroid status` 能进入 RUNNING；
- `system.img` / `vendor.img` 的 loop 分配由 Ubuntu 容器内的 mount 自动完成；
- 停止 Waydroid 后自动 loop 应可释放，不需要 fnOS 开机服务维护固定 loop 编号。

## 注意

Linux loop 设备是宿主内核的全局资源。当前方案允许桌面容器访问 loop major 7，因此其隔离强度低于旧版“只映射两个预分配 loop”的方案，但仍明显小于 `privileged: true` 或暴露全部宿主块设备。该取舍是为了获得真正的桌面系统体验：Android 镜像安装、更新和启动全部在 Ubuntu 内完成。
