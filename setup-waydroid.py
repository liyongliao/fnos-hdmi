#!/usr/bin/env python3
"""Run on fnOS as root, after downloading images in the Ubuntu desktop."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent
SERVICE = 'fnos-waydroid-desktop.service'

def run(*args, capture=False, env=None):
    return subprocess.run(args, check=True, text=True, env=env,
                          stdout=subprocess.PIPE if capture else None).stdout

def start():
    os.chdir(PROJECT)
    command = ['docker', 'compose', '--progress', 'plain', '-f', 'compose.yaml']
    if (PROJECT / 'compose.override.yaml').exists():
        command += ['-f', 'compose.override.yaml']
    config = json.loads(run(*command, 'config', '--format', 'json', capture=True))
    desktop = config['services']['ubuntu26-gnome-hdmi']
    if desktop.get('network_mode') == 'host':
        raise RuntimeError('Waydroid requires a private Docker network, not host networking')
    data = next(Path(v['source']) for v in desktop['volumes']
                if v['target'] == '/var/lib/waydroid' and v['type'] == 'bind')
    if not (data / 'waydroid.cfg').is_file():
        raise RuntimeError('请先在 Ubuntu 内完成 Waydroid 初始化和镜像下载。')
    images = [data / 'images' / name for name in ('system.img', 'vendor.img')]
    for image in images:
        if not image.is_file() or image.stat().st_size == 0:
            raise RuntimeError(f'Android 镜像不存在或为空：{image}')
    env = os.environ.copy()
    binder = [line.split()[0] for line in Path('/proc/devices').read_text().splitlines()
              if len(line.split()) == 2 and line.split()[1] == 'binder']
    if not binder:
        raise RuntimeError('fnOS 内核未注册 Binder 驱动，未启动 Waydroid 桌面。')
    env['BINDER_DEVICE_MAJOR'] = binder[0]
    for key, image in zip(('WAYDROID_SYSTEM_LOOP', 'WAYDROID_VENDOR_LOOP'), images):
        rows = run('losetup', '--associated', str(image.resolve()), '--noheadings',
                   '--output', 'NAME,RO', capture=True).splitlines()
        readonly = [row.split()[0] for row in rows if row.split()[-1] == '1']
        if rows and not readonly:
            raise RuntimeError(f'{image} 已被读写 loop 使用，请先停止相关程序，未修改其设备。')
        device = readonly[0] if readonly else run('losetup', '--find', '--show',
                    '--read-only', str(image.resolve()), capture=True).strip()
        env[key] = device
        print(f'{image.name}: {device} (read-only)', flush=True)
    run(*command, '-f', 'compose.waydroid.yaml', 'up', '-d', '--no-deps',
        'ubuntu26-gnome-hdmi', env=env)

def install():
    def quote(value):
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
    unit = Path('/etc/systemd/system') / SERVICE
    marker = '# Managed by setup-waydroid.py\n'
    if unit.exists() and (marker not in unit.read_text() or quote(PROJECT / 'setup-waydroid.py') not in unit.read_text()):
        raise RuntimeError(f'{unit} 已存在且不属于当前项目，未覆盖。')
    unit.write_text(marker + '[Unit]\nDescription=fnOS Waydroid desktop device preparation\n'
        'Requires=docker.service\nAfter=docker.service local-fs.target\n'
        f'RequiresMountsFor={quote(PROJECT)}\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n'
        f'ExecStart=/usr/bin/python3 {quote(PROJECT / "setup-waydroid.py")}\n'
        'ExecStop=/usr/bin/docker stop --time 20 ubuntu26-gnome-hdmi\n'
        'TimeoutStartSec=120\nTimeoutStopSec=40\n\n[Install]\nWantedBy=multi-user.target\n')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', SERVICE)
    # Starting an inactive unit prepares devices immediately. For a running
    # unit, refresh Compose without stopping the desktop unnecessarily.
    active = subprocess.run(['systemctl', 'is-active', '--quiet', SERVICE]).returncode == 0
    if active:
        start()
    else:
        run('systemctl', 'start', SERVICE)

if __name__ == '__main__':
    if os.geteuid() != 0:
        raise SystemExit('请在飞牛 SSH 中运行：sudo python3 setup-waydroid.py --install-autostart')
    if sys.argv[1:] == ['--install-autostart']:
        install()
    elif not sys.argv[1:]:
        with open('/run/fnos-waydroid-desktop.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            start()
    else:
        raise SystemExit('Usage: setup-waydroid.py [--install-autostart]')
