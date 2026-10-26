#!/usr/bin/env python3
"""One-time, interactive Mac administrator operation; services run as the owner."""
import argparse
import grp
import os
from pathlib import Path
import plistlib
import pwd
import re
import subprocess

PREFIX = 'com.server-tooling.monitoring.'


def boot_plist(value, label, user):
    if value.get('Label') != label or not re.fullmatch(re.escape(PREFIX) + r'[a-z0-9-]+', label):
        raise ValueError('Unexpected service label')
    value = dict(value, UserName=user.pw_name, GroupName=grp.getgrgid(user.pw_gid).gr_name)
    value['RunAtLoad'] = True
    value['KeepAlive'] = True
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('user')
    parser.add_argument('--services', nargs='+', help='Only migrate these monitoring service names')
    parser.add_argument('--check', action='store_true', help='Validate and list changes without installing')
    args = parser.parse_args()
    root = args.root.resolve()
    user = pwd.getpwnam(args.user)
    if root != Path(user.pw_dir) / '.local/share/server-tooling-monitoring':
        raise SystemExit('Unexpected installation directory')
    if not args.check and os.geteuid() != 0:
        raise SystemExit('Run through the generated enable-boot.sh as the installation owner')
    agents = Path(user.pw_dir) / 'Library/LaunchAgents'
    daemons = Path('/Library/LaunchDaemons')
    names = args.services or [p.name[len(PREFIX):-6] for p in sorted(agents.glob(PREFIX + '*.plist'))]
    planned = []
    # Preflight the entire selection before stopping any service.
    for name in names:
        if not re.fullmatch(r'[a-z0-9-]+', name):
            raise SystemExit('Invalid service name: ' + name)
        label = PREFIX + name
        filename = label + '.plist'
        source = agents / filename
        destination = daemons / filename
        staged = root / filename
        if destination.exists():
            source = staged if staged.exists() else destination
        value = boot_plist(plistlib.loads(source.read_bytes()), label, user)
        planned.append((label, destination, value))
    for label, destination, value in planned:
        if args.check:
            print('Boot service:', label, 'as', user.pw_name)
            continue
        previous = destination.read_bytes() if destination.exists() else None
        destination.write_bytes(plistlib.dumps(value))
        os.chown(destination, 0, 0)
        destination.chmod(0o644)
        for domain in [f'gui/{user.pw_uid}', f'user/{user.pw_uid}', 'system']:
            subprocess.run(['launchctl', 'bootout', domain + '/' + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            subprocess.run(['launchctl', 'enable', 'system/' + label], check=True)
            subprocess.run(['launchctl', 'bootstrap', 'system', str(destination)], check=True)
        except subprocess.CalledProcessError:
            if previous is not None:
                destination.write_bytes(previous)
                subprocess.run(['launchctl', 'bootstrap', 'system', str(destination)])
            else:
                destination.unlink()
                agent = agents / destination.name
                domain = f'gui/{user.pw_uid}'
                if subprocess.run(['launchctl', 'print', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                    domain = f'user/{user.pw_uid}'
                subprocess.run(['launchctl', 'bootstrap', domain, str(agent)])
            raise
        legacy = agents / destination.name
        if legacy.exists():
            saved = root / 'backups/retired-login-agents' / legacy.name
            saved.parent.mkdir(parents=True, exist_ok=True)
            legacy.replace(saved)
        print('Enabled at boot:', label)


if __name__ == '__main__':
    main()
