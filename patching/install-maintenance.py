#!/usr/bin/env python3
"""Install unattended security updates, weekly upgrades/reports and Saturday reboots on Ubuntu over SSH."""
import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'monitoring/platform'))
from install import run, ssh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', help='SSH alias or user@hostname; requires passwordless sudo')
    parser.add_argument('--email', default='mike.wagstaff@gmail.com')
    parser.add_argument('--from-email', default='alerts@skynolimit.dev')
    parser.add_argument('--user-unit', action='append', default=[], help='User .service to check in reports; repeat as needed')
    parser.add_argument('--skip-caddy', action='store_true', help='Leave Caddy package source unchanged (e.g. custom builds)')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@-]*', args.host):
        parser.error('Use an SSH host alias or user@hostname')
    for unit in args.user_unit:
        if not re.fullmatch(r'[A-Za-z0-9_.@:-]+\.service', unit):
            parser.error('User units must be service names ending in .service')
    source = Path(__file__).resolve().parent
    ssh(args.host, ['sudo', '-n', 'true'])
    remote = ssh(args.host, ['mktemp', '-d'], capture_output=True, text=True).stdout.strip()
    try:
        for name in ['maintenance-host.py', 'weekly-reboot.py']:
            run(['scp', '-q', source / name, args.host + ':' + remote + '/' + name])
        ssh(args.host, ['sudo', '-n', 'python3', remote + '/maintenance-host.py', remote])
        report_args = [sys.executable, source / 'install-upgrade-report.py', args.host,
                       '--email', args.email, '--from-email', args.from_email]
        for unit in args.user_unit:
            report_args.extend(['--user-unit', unit])
        run(report_args)
        installed = ssh(args.host, ['python3', '-c', 'import subprocess; print(subprocess.run(["dpkg-query","-W","-f=${db:Status-Status}","caddy"],capture_output=True,text=True).stdout.strip())'],
                        capture_output=True, text=True).stdout.strip() if not args.skip_caddy else ''
        if installed == 'installed':
            run([sys.executable, source / 'configure-caddy-updates.py', args.host, '--apply'])
        ssh(args.host, ['sudo', '-n', 'python3', remote + '/maintenance-host.py', remote, '--enable'])
    finally:
        ssh(args.host, ['rm', '-rf', remote])
    print('Maintenance installed. Reboots: Saturday 04:00 Europe/London. No reboot or full upgrade was run.')


if __name__ == '__main__':
    main()
