#!/usr/bin/env python3
"""Adapt Waydroid for the fnOS Docker desktop without a host-side mode switch."""
from pathlib import Path

# Compose already sets IPv4 forwarding inside this private network namespace.
# Avoid failing when Docker exposes that sysctl read-only to the nested script.
path = Path('/usr/lib/waydroid/data/scripts/waydroid-net.sh')
if path.exists():
    original = path.read_text()
    old = 'echo 1 > /proc/sys/net/ipv4/ip_forward'
    new = '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || echo 1 > /proc/sys/net/ipv4/ip_forward'
    if new not in original:
        if old not in original:
            raise SystemExit('Unsupported waydroid-net.sh: IPv4 forwarding statement not found')
        path.write_text(original.replace(old, new))

# Waydroid upstream mounts system.img/vendor.img directly. Before that happens,
# run the fnOS compatibility preparation against the downloaded system image.
# This hook is inside the Waydroid container manager, so it also covers the very
# first session immediately after the GUI finishes downloading Android images.
path = Path('/usr/lib/waydroid/tools/actions/container_manager.py')
if path.exists():
    original = path.read_text()
    marker = '# fnOS single-runtime image preparation'
    if marker not in original:
        needle = (
            '    # Mount rootfs\n'
            '    cfg = tools.config.load(args)\n'
            '    helpers.images.mount_rootfs(args, cfg["waydroid"]["images_path"], session)\n'
        )
        replacement = (
            '    # fnOS single-runtime image preparation\n'
            '    fnos_prepare = "/usr/local/sbin/prepare-waydroid-runtime"\n'
            '    if os.path.exists(fnos_prepare):\n'
            '        tools.helpers.run.user(args, [fnos_prepare])\n\n'
            + needle
        )
        if needle not in original:
            raise SystemExit('Unsupported container_manager.py: rootfs mount block not found')
        path.write_text(original.replace(needle, replacement, 1))
