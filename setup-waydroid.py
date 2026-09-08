#!/usr/bin/env python3
"""Migrate old fnOS Waydroid two-stage installs to the single Docker runtime.

Waydroid no longer needs host-prepared loop devices or a fnOS boot service.
This command is retained so old README/history commands remain safe.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent
SERVICE = 'fnos-waydroid-desktop.service'
DESKTOP_SERVICE = 'ubuntu26-gnome-hdmi'


def run(*args, capture=False, check=True):
    result = subprocess.run(
        args,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout if capture else ''


def compose_command():
    command = ['docker', 'compose', '--progress', 'plain', '-f', 'compose.yaml']
    if (PROJECT / 'compose.override.yaml').exists():
        command += ['-f', 'compose.override.yaml']
    return command


def waydroid_data_dir(command):
    config = json.loads(run(*command, 'config', '--format', 'json', capture=True))
    desktop = config['services'][DESKTOP_SERVICE]
    try:
        return next(
            Path(v['source'])
            for v in desktop['volumes']
            if v['target'] == '/var/lib/waydroid' and v['type'] == 'bind'
        )
    except StopIteration as exc:
        raise RuntimeError('compose.yaml 缺少 /var/lib/waydroid 持久化目录。') from exc


def remove_legacy_service():
    unit = Path('/etc/systemd/system') / SERVICE
    if not unit.exists():
        return False
    content = unit.read_text(errors='replace')
    if not content.startswith('# Managed by setup-waydroid.py'):
        print(f'保留非本项目管理的 systemd 服务：{unit}')
        return False

    run('systemctl', 'disable', '--now', SERVICE, check=False)
    unit.unlink(missing_ok=True)
    run('systemctl', 'daemon-reload')
    print('已移除旧版 fnOS Waydroid 双模式开机服务。')
    return True


def detach_legacy_loops(data):
    for name in ('system.img', 'vendor.img'):
        image = data / 'images' / name
        if not image.exists():
            continue
        output = run(
            'losetup', '--associated', str(image.resolve()), '--noheadings',
            '--output', 'NAME,RO', capture=True, check=False,
        )
        for row in output.splitlines():
            fields = row.split()
            if len(fields) < 2 or fields[-1] != '1':
                continue
            device = fields[0]
            result = subprocess.run(['losetup', '-d', device], check=False)
            if result.returncode == 0:
                print(f'已释放旧版只读 loop：{device} ({name})')


def migrate():
    os.chdir(PROJECT)
    command = compose_command()
    data = waydroid_data_dir(command)

    # Stop the legacy container/service first so its host loop devices are no
    # longer held open. Then recreate the desktop once with the new loop cgroup
    # permissions; from that point Android image lifecycle stays inside Ubuntu.
    removed = remove_legacy_service()
    if removed:
        detach_legacy_loops(data)

    run(*command, 'up', '-d', '--force-recreate', '--no-deps', DESKTOP_SERVICE)
    print('')
    print('Waydroid 已切换为单一 Docker 运行模式。')
    print('以后直接在 Ubuntu 中初始化/更新/启动 Android，不再需要本脚本。')


if __name__ == '__main__':
    if os.geteuid() != 0:
        raise SystemExit('请在飞牛 SSH 中使用 sudo 运行此兼容迁移脚本。')
    if sys.argv[1:] in ([], ['--install-autostart'], ['--migrate']):
        migrate()
    else:
        raise SystemExit('Usage: setup-waydroid.py [--migrate]')
