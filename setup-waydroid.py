#!/usr/bin/env python3
"""Prepare the fnOS desktop for Waydroid, with a safe first-boot fallback."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent
SERVICE = 'fnos-waydroid-desktop.service'
DESKTOP_SERVICE = 'ubuntu26-gnome-hdmi'


def run(*args, capture=False, env=None):
    return subprocess.run(
        args,
        check=True,
        text=True,
        env=env,
        stdout=subprocess.PIPE if capture else None,
    ).stdout


def compose_command():
    command = ['docker', 'compose', '--progress', 'plain', '-f', 'compose.yaml']
    if (PROJECT / 'compose.override.yaml').exists():
        command += ['-f', 'compose.override.yaml']
    return command


def desktop_config(command):
    config = json.loads(run(*command, 'config', '--format', 'json', capture=True))
    desktop = config['services'][DESKTOP_SERVICE]
    if desktop.get('network_mode') == 'host':
        raise RuntimeError('Waydroid requires a private Docker network, not host networking')
    return desktop


def waydroid_data_dir(desktop):
    try:
        return next(
            Path(v['source'])
            for v in desktop['volumes']
            if v['target'] == '/var/lib/waydroid' and v['type'] == 'bind'
        )
    except StopIteration as exc:
        raise RuntimeError('compose.yaml 缺少 /var/lib/waydroid 持久化目录。') from exc


def missing_android_assets(data):
    required = [
        data / 'waydroid.cfg',
        data / 'images' / 'system.img',
        data / 'images' / 'vendor.img',
    ]
    missing = []
    for path in required:
        if not path.is_file() or path.stat().st_size == 0:
            missing.append(path)
    return missing


def start_base_desktop(command, data, missing):
    print('', flush=True)
    print('Waydroid 尚未完成首次初始化；先启动普通 Ubuntu GNOME 桌面。', flush=True)
    print(f'Waydroid 数据目录：{data}', flush=True)
    for path in missing:
        print(f'  等待生成：{path}', flush=True)
    print('', flush=True)
    print('现在可通过 HDMI、3389 或 8080 进入 Ubuntu。', flush=True)
    print('在 Ubuntu 中启动 Waydroid，选择 Vanilla/GAPPS 并等待镜像下载完成。', flush=True)
    print('完成后回到 fnOS SSH 执行：', flush=True)
    print(f'  sudo python3 {PROJECT / "setup-waydroid.py"} --install-autostart', flush=True)
    print('', flush=True)

    # This is intentionally the base desktop only. Do not include
    # compose.waydroid.yaml until system.img/vendor.img actually exist.
    run(*command, 'up', '-d', '--no-deps', DESKTOP_SERVICE)
    return False


def start():
    """Start the desktop; transparently use bootstrap mode before Waydroid init."""
    os.chdir(PROJECT)
    command = compose_command()
    desktop = desktop_config(command)
    data = waydroid_data_dir(desktop)
    missing = missing_android_assets(data)

    if missing:
        return start_base_desktop(command, data, missing)

    env = os.environ.copy()
    binder = [
        line.split()[0]
        for line in Path('/proc/devices').read_text().splitlines()
        if len(line.split()) == 2 and line.split()[1] == 'binder'
    ]
    if not binder:
        raise RuntimeError('fnOS 内核未注册 Binder 驱动，未启动 Waydroid 桌面。')
    env['BINDER_DEVICE_MAJOR'] = binder[0]

    images = [data / 'images' / name for name in ('system.img', 'vendor.img')]
    for key, image in zip(('WAYDROID_SYSTEM_LOOP', 'WAYDROID_VENDOR_LOOP'), images):
        rows = run(
            'losetup',
            '--associated',
            str(image.resolve()),
            '--noheadings',
            '--output',
            'NAME,RO',
            capture=True,
        ).splitlines()
        readonly = [row.split()[0] for row in rows if row.split()[-1] == '1']
        if rows and not readonly:
            raise RuntimeError(f'{image} 已被读写 loop 使用，请先停止相关程序，未修改其设备。')
        device = readonly[0] if readonly else run(
            'losetup',
            '--find',
            '--show',
            '--read-only',
            str(image.resolve()),
            capture=True,
        ).strip()
        env[key] = device
        print(f'{image.name}: {device} (read-only)', flush=True)

    print('Waydroid 镜像已就绪，切换到完整 Waydroid 设备模式。', flush=True)
    run(
        *command,
        '-f',
        'compose.waydroid.yaml',
        'up',
        '-d',
        '--no-deps',
        DESKTOP_SERVICE,
        env=env,
    )
    return True


def install():
    def quote(value):
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'

    unit = Path('/etc/systemd/system') / SERVICE
    marker = '# Managed by setup-waydroid.py\n'
    if unit.exists() and (
        marker not in unit.read_text()
        or quote(PROJECT / 'setup-waydroid.py') not in unit.read_text()
    ):
        raise RuntimeError(f'{unit} 已存在且不属于当前项目，未覆盖。')

    unit.write_text(
        marker
        + '[Unit]\nDescription=fnOS Waydroid desktop device preparation\n'
        'Requires=docker.service\nAfter=docker.service local-fs.target\n'
        f'RequiresMountsFor={quote(PROJECT)}\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n'
        f'ExecStart=/usr/bin/python3 {quote(PROJECT / "setup-waydroid.py")}\n'
        'ExecStop=/usr/bin/docker stop --time 45 ubuntu26-gnome-hdmi\n'
        'TimeoutStartSec=180\nTimeoutStopSec=60\n\n[Install]\nWantedBy=multi-user.target\n'
    )
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', SERVICE)

    # It is safe to install autostart before Android images exist. In that
    # case start() launches the ordinary Ubuntu desktop so the user can do
    # Waydroid's first-run initialization, instead of failing with a deadlock.
    active = subprocess.run(['systemctl', 'is-active', '--quiet', SERVICE]).returncode == 0
    if active:
        ready = start()
    else:
        run('systemctl', 'start', SERVICE)
        # ExecStart runs this same script and chooses bootstrap/full mode.
        command = compose_command()
        ready = not missing_android_assets(waydroid_data_dir(desktop_config(command)))

    if ready:
        print('Waydroid 开机服务已启用，Android 镜像已就绪。', flush=True)
    else:
        print('Waydroid 开机服务已启用；当前处于首次初始化的 Ubuntu 桌面模式。', flush=True)


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
