#!/usr/bin/env python3
"""Avoid unnecessary writes to Docker's read-only proc sysctl mounts."""
from pathlib import Path

path = Path('/usr/lib/waydroid/data/scripts/waydroid-net.sh')
if path.exists():
    original = path.read_text()
    old = 'echo 1 > /proc/sys/net/ipv4/ip_forward'
    new = '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || echo 1 > /proc/sys/net/ipv4/ip_forward'
    if new not in original:
        if old not in original:
            raise SystemExit('Unsupported waydroid-net.sh: IPv4 forwarding statement not found')
        path.write_text(original.replace(old, new))

# Host-prepared, read-only loop devices: never expose loop-control or all disks.
path = Path('/usr/lib/waydroid/tools/helpers/images.py')
if path.exists() and Path('/dev/waydroid-system').exists():
    original = path.read_text()
    updated = original.replace('images_dir + "/system.img",', '\"/dev/waydroid-system\",')
    updated = updated.replace('images_dir + "/vendor.img",', '\"/dev/waydroid-vendor\",')
    if updated != original:
        path.write_text(updated)
