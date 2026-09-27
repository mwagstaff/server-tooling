#!/usr/bin/env python3
"""Root-side maintenance setup, invoked by install-maintenance.py."""
import datetime
import os
from pathlib import Path
import shutil
import subprocess
import sys

REBOOT_CALENDAR = 'Sat *-*-* 04:00:00 Europe/London'
SYSTEMD = Path('/etc/systemd/system')


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if release.get('ID', '').strip('"') != 'ubuntu':
        raise SystemExit('This installer supports Ubuntu with systemd and APT.')
    stage = Path(sys.argv[1])
    if '--enable' in sys.argv:
        run(['systemctl', 'daemon-reload'])
        run(['systemd-analyze', 'verify', str(SYSTEMD / 'server-tooling-weekly-reboot.service'),
             str(SYSTEMD / 'server-tooling-weekly-reboot.timer'), str(SYSTEMD / 'server-tooling-full-upgrade.service')])
        run(['systemctl', 'enable', '--now', 'apt-daily.timer', 'apt-daily-upgrade.timer',
             'server-tooling-full-upgrade.timer', 'server-tooling-weekly-reboot.timer'])
        # Restart only the timer so reruns also apply a changed calendar. Never start its service here.
        run(['systemctl', 'restart', 'server-tooling-weekly-reboot.timer'])
        run(['systemctl', 'list-timers', 'server-tooling-*', '--no-pager'])
        return
    run(['systemd-analyze', 'calendar', REBOOT_CALENDAR])
    required = ['python3-apt', 'unattended-upgrades', 'needrestart', 'ubuntu-pro-client', 'gnupg', 'ca-certificates', 'tzdata']
    missing = [name for name in required if subprocess.run(['dpkg-query', '-W', '-f=${db:Status-Status}', name],
               capture_output=True, text=True).stdout.strip() != 'installed']
    if missing:
        env = dict(os.environ, DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l')
        run(['apt-get', '-o', 'APT::Update::Error-Mode=any', 'update'], env=env)
        run(['apt-get', '-y', '-o', 'Dpkg::Options::=--force-confdef', '-o', 'Dpkg::Options::=--force-confold', 'install', *missing], env=env)
    backup = Path('/var/backups/server-tooling/maintenance-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    backup.mkdir(parents=True, mode=0o700)

    def put(path, text, mode=0o644, only_missing=False):
        path = Path(path)
        if path.exists() and (only_missing or path.read_text() == text):
            return
        if path.exists():
            saved = backup / str(path).lstrip('/')
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, saved)
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + '.new')
        temp.write_text(text)
        temp.chmod(mode)
        temp.replace(path)

    put('/etc/apt/apt.conf.d/60-server-tooling-maintenance',
        'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
        'Unattended-Upgrade::Origins-Pattern:: "origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu";\n'
        'Unattended-Upgrade::Origins-Pattern:: "origin=UbuntuESMApps,codename=${distro_codename}-apps-security,label=UbuntuESMApps";\n'
        'Unattended-Upgrade::Origins-Pattern:: "origin=UbuntuESM,codename=${distro_codename}-infra-security,label=UbuntuESM";\n'
        '// Reboots belong to the explicit weekly timer, in Europe/London time.\n'
        'Unattended-Upgrade::Automatic-Reboot "false";\n')
    put('/usr/local/sbin/server-tooling-full-upgrade',
        '#!/bin/bash\nset -euo pipefail\nexport DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a\n'
        'apt-get -o APT::Update::Error-Mode=any update\n'
        'apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade -y\n'
        'apt-get autoremove --purge -y\napt-get autoclean -y\n', 0o755, only_missing=True)
    put(SYSTEMD / 'server-tooling-full-upgrade.service',
        '[Unit]\nDescription=Server Tooling weekly apt full-upgrade\nAfter=network-online.target\nWants=network-online.target\n'
        '[Service]\nType=oneshot\nExecStart=/usr/local/sbin/server-tooling-full-upgrade\nNice=10\n'
        'IOSchedulingClass=best-effort\nIOSchedulingPriority=7\n', only_missing=True)
    put(SYSTEMD / 'server-tooling-full-upgrade.timer',
        '[Unit]\nDescription=Run Server Tooling weekly apt full-upgrade\n'
        '[Timer]\nOnCalendar=Sun *-*-* 04:00:00 UTC\nPersistent=true\nRandomizedDelaySec=20m\n'
        '[Install]\nWantedBy=timers.target\n', only_missing=True)
    put('/usr/local/lib/server-tooling/weekly-reboot.py', (stage / 'weekly-reboot.py').read_text(), 0o755)
    put(SYSTEMD / 'server-tooling-weekly-reboot.service',
        '[Unit]\nDescription=Scheduled weekly host reboot\nAfter=network.target\n'
        '[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /usr/local/lib/server-tooling/weekly-reboot.py\nTimeoutStartSec=35min\n')
    put(SYSTEMD / 'server-tooling-weekly-reboot.timer',
        '[Unit]\nDescription=Reboot Saturday at 04:00 UK time\n'
        '[Timer]\nOnCalendar=' + REBOOT_CALENDAR + '\nAccuracySec=1s\nRandomizedDelaySec=0\nPersistent=false\n'
        '[Install]\nWantedBy=timers.target\n')
    run(['systemctl', 'daemon-reload'])
    print('Maintenance files installed; existing weekly upgrade schedule preserved. Backups:', backup)


if __name__ == '__main__':
    main()
