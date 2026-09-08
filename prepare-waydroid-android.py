"""Keep Android logd from requiring host kernel logging/audit privileges."""
from pathlib import Path
import configparser
import sys
import os
import stat

root = Path('/var/lib/waydroid')
source = Path(sys.argv[1]) / 'system/etc/init/logd.rc' if len(sys.argv) > 1 else root / 'rootfs/system/etc/init/logd.rc'
target = root / 'overlay/system/etc/init/logd.rc'
content = source.read_text()
for line in ('    file /proc/kmsg r\n', '    file /dev/kmsg w\n',
             '    capabilities SYSLOG AUDIT_CONTROL\n',
             '    capabilities AUDIT_CONTROL\n',
             '    start logd-auditctl\n'):
    content = content.replace(line, '')
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(content)

# Newly generated GAPPS idmaps may inherit fnOS ACLs during first boot. Repair
# only these public resource indexes until Android finishes booting. Never
# chmod application databases, accounts, photos, or the whole data directory.
rc = root / 'overlay/system/etc/init/fnos-resource-cache.rc'
rc.write_text('service fnos-resource-cache /system/bin/sh /system/etc/fnos-resource-cache.sh\n'
              '    user root\n    group root\n    disabled\n    oneshot\n\n'
              'on post-fs-data\n    start fnos-resource-cache\n')
script = root / 'overlay/system/etc/fnos-resource-cache.sh'
script.write_text('''#!/system/bin/sh
i=0
while [ "$i" -lt 300 ]; do
    for item in /data/resource-cache/*@idmap; do
        if [ -f "$item" ] && [ ! -L "$item" ]; then
            chmod 0644 "$item"
        fi
    done
    [ "$(getprop sys.boot_completed)" = 1 ] && exit 0
    i=$((i + 1))
    sleep 1
done
''')
script.chmod(0o644)
cfg_path = root / 'waydroid.cfg'
cfg = configparser.ConfigParser()
cfg.read(cfg_path)
if not cfg.has_section('properties'):
    cfg.add_section('properties')
cfg['properties']['ro.logd.kernel'] = 'false'
cfg['properties']['ro.logd.auditd'] = 'false'
with cfg_path.open('w') as stream:
    cfg.write(stream)

# Waydroid 1.6 builds session properties from this generated file, not directly
# from waydroid.cfg. Keep both in sync without reinitializing downloaded images.
base = root / 'waydroid_base.prop'
properties = {'ro.logd.kernel': 'false', 'ro.logd.auditd': 'false'}
lines = [line for line in base.read_text().splitlines()
         if line.split('=', 1)[0] not in properties]
base.write_text('\n'.join(lines + [f'{k}={v}' for k, v in properties.items()]) + '\n')

# These generated resource maps contain no app/private data. fnOS inherited
# ACLs can create them as 0701, preventing zygote's preload from reading them.
user = os.environ.get('DESKTOP_USER', 'ubuntu')
cache = Path('/home') / user / '.local/share/waydroid/data/resource-cache'
if cache.is_dir():
    for item in cache.glob('*@idmap'):
        if stat.S_ISREG(item.lstat().st_mode):
            item.chmod(0o644)
