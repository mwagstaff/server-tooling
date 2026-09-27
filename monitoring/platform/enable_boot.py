#!/usr/bin/env python3
"""One-time, interactive Mac administrator operation; services run as the owner."""
import os
from pathlib import Path
import plistlib
import pwd
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
user = pwd.getpwnam(sys.argv[2])
if os.geteuid() != 0 or root != Path(user.pw_dir) / '.local/share/server-tooling-monitoring':
    raise SystemExit('Run through the generated enable-boot.sh as the installation owner')
agents = Path(user.pw_dir) / 'Library/LaunchAgents'
for source in sorted(agents.glob('com.server-tooling.monitoring.*.plist')):
    value = plistlib.loads(source.read_bytes())
    label = value['Label']
    if label + '.plist' != source.name or not label.startswith('com.server-tooling.monitoring.'):
        raise SystemExit('Unexpected service label')
    staged = root / source.name
    if staged.exists():
        value = plistlib.loads(staged.read_bytes())
    value['UserName'] = user.pw_name
    value['GroupName'] = __import__('grp').getgrgid(user.pw_gid).gr_name
    destination = Path('/Library/LaunchDaemons') / source.name
    destination.write_bytes(plistlib.dumps(value))
    os.chown(destination, 0, 0)
    destination.chmod(0o644)
    for domain in [f'gui/{user.pw_uid}', f'user/{user.pw_uid}', 'system']:
        subprocess.run(['launchctl', 'bootout', domain + '/' + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['launchctl', 'bootstrap', 'system', str(destination)], check=True)
    print('Enabled at boot:', label)
