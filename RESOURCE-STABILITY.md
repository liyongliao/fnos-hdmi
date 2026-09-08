# 资源与稳定性说明

主 GNOME/Waydroid 桌面默认采用“桌面电脑模式”：不设置 RAM、swap 或 PID 硬上限。

原因是完整 GNOME、Chrome/Chromium、远程桌面以及 Waydroid/GAPPS 的瞬时资源需求会明显超过旧版 4/6GB 与 2048/8192 PID 的限制，旧配置容易触发 cgroup OOM 或线程/进程上限。

## 默认启动

```bash
sudo docker compose --profile web up -d --force-recreate
```

## 可选：限制桌面资源

只有在确实需要保护 NAS 其余服务时，才叠加：

```bash
sudo docker compose \
  -f compose.yaml \
  -f compose.resource-limits.yaml \
  --profile web up -d --force-recreate
```

默认可选上限：

- RAM: 12GB
- RAM + swap 总量: 16GB
- PID/线程: 16384

可以在 `.env` 调整：

```ini
DESKTOP_MEMORY_LIMIT=12g
DESKTOP_MEMORY_SWAP_LIMIT=16g
DESKTOP_PIDS_LIMIT=16384
```

注意：Docker 的 `memswap_limit` 表示 RAM + swap 的总额度，而不是额外 swap。若它与 `mem_limit` 相同，就没有 swap 缓冲。

## 诊断异常停止

```bash
chmod +x resource-diagnostic.sh
./resource-diagnostic.sh
```

脚本会显示：

- Docker OOMKilled / ExitCode / RestartCount
- 实际 Memory / MemorySwap / PidsLimit
- 当前资源使用
- fnOS 宿主机内存与 swap
- 内核 OOM / memory cgroup 日志
- cgroup v2 `memory.events`

## 为什么不直接 privileged

当前主配置已经开放 Waydroid/桌面需要的高权限 capability，并使用 `apparmor=unconfined` 与 `seccomp=unconfined`；同时只映射物理 PF 的 `/dev/dri/card0` 与 `/dev/dri/renderD128`。

这台 fnOS 还有其他 SR-IOV DRM 设备。直接使用 `privileged: true` 会扩大设备访问范围，并可能让 Mutter/GDM 枚举原本刻意隔离的 VF。普通 Linux 软件安装只需要容器内 root/sudo 和可写 rootfs，并不要求 privileged。
