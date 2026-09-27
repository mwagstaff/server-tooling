#!/usr/bin/env python3
"""Install upgrade reports, host event recording and bounded tunnel shutdown.

Uses the existing weekly upgrade timer and a deployed or Bitwarden Plunk secret. Does not run an upgrade
or restart the tunnel. Run from the repository: python3 patching/install-upgrade-report.py sky
"""
import argparse
import json
import os
import re
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'monitoring/platform'))
from install import get_secret, vault_items, run, ssh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--email', default='mike.wagstaff@gmail.com')
    parser.add_argument('--from-email', default='alerts@skynolimit.dev')
    parser.add_argument('--user-unit', action='append', default=None,
                        help='User service to check; repeat for each service (defaults to known inventory)')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@-]*', args.host):
        parser.error('Use an SSH host alias or user@hostname')
    info = json.loads(ssh(args.host, ['python3', '-c',
        'import json,os,platform; print(json.dumps({"home":os.path.expanduser("~"),"os":platform.system().lower(),"host":platform.node()}))'],
        capture_output=True, text=True).stdout)
    if info['os'] != 'linux':
        parser.error('The weekly APT report is for Linux hosts')
    source = Path(__file__).resolve().parent / 'weekly-report'
    inventory = json.loads((source.parents[1] / 'monitoring/platform/inventory.json').read_text())
    services = inventory['hosts'].get(args.host, {}).get('services', [])
    units = args.user_unit if args.user_unit is not None else [service['unit'] + '.service' for service in services]
    for unit in units:
        if not re.fullmatch(r'[A-Za-z0-9_.@:-]+\.service', unit):
            parser.error('User units must be service names ending in .service')
    available = ssh(args.host, ['sudo', '-n', 'python3', '-c',
        'import pathlib,sys; print(any(p.is_file() and p.stat().st_size for p in '
        '[pathlib.Path("/etc/server-tooling/weekly-upgrade.smtp-password"), pathlib.Path(sys.argv[1])/"monitoring/secrets/plunk-smtp-password"]))',
        info['home']], capture_output=True, text=True).stdout.strip() == 'True'
    secret_value = os.environ.get('PLUNK_SECRET_KEY') or (None if available else
        get_secret(vault_items(), 'PLUNK_SECRET_KEY', app=None))
    remote = ssh(args.host, ['mktemp', '-d'], capture_output=True, text=True).stdout.strip()
    try:
        if secret_value:
            # Credential travels on encrypted stdin, never in the remote command line.
            ssh(args.host, ['python3', '-c',
                'import os,sys; os.umask(0o077); open(sys.argv[1],"w").write(sys.stdin.read())',
                remote + '/smtp-password'], input=secret_value, text=True)
        for name in ['events.py', 'report.py', 'email_format.py']:
            run(['scp', '-q', source / name, args.host + ':' + remote + '/' + name])
        code = '''import datetime,json,pathlib,pwd,shutil,subprocess,sys
staged,home,email,sender,hostname,units=sys.argv[1:]
root=pathlib.Path('/usr/local/lib/server-tooling')
config_dir=pathlib.Path('/etc/server-tooling')
secret=next((p for p in [pathlib.Path(staged)/'smtp-password',config_dir/'weekly-upgrade.smtp-password',
 pathlib.Path(home)/'monitoring/secrets/plunk-smtp-password'] if p.is_file() and p.stat().st_size),None)
subprocess.run(['systemctl','cat','server-tooling-full-upgrade.service'],check=True,stdout=subprocess.DEVNULL)
has_tunnel=subprocess.run(['systemctl','cat','cloudflared.service'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
if secret is None: raise SystemExit('Existing Plunk SMTP credential missing')
backup=pathlib.Path('/var/backups/server-tooling')/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
backup.mkdir(parents=True,mode=0o700)
def put(path,text,mode=0o644):
 p=pathlib.Path(path); p.parent.mkdir(parents=True,exist_ok=True)
 if p.exists():
  saved=backup/str(p).lstrip('/'); saved.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,saved)
 temp=p.with_suffix(p.suffix+'.new'); temp.write_text(text); temp.chmod(mode); temp.replace(p)
for name in ['events.py','report.py','email_format.py']:
 put(root/name,(pathlib.Path(staged)/name).read_text(),0o755)
config_dir.mkdir(mode=0o700,exist_ok=True)
put(config_dir/'weekly-upgrade.smtp-password',secret.read_text(),0o600)
owner=pwd.getpwuid(pathlib.Path(home).stat().st_uid)
system_units=['server-tooling-full-upgrade.timer','unattended-upgrades']
for unit in ['caddy.service','cloudflared.service','server-tooling-weekly-reboot.timer']:
 if subprocess.run(['systemctl','cat',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0: system_units.append(unit)
config={'host':hostname,'system_units':system_units,'to':email,'from':sender,'smtp_host':'next-smtp.useplunk.com','smtp_port':2587,'smtp_user':'plunk',
 'password_file':str(config_dir/'weekly-upgrade.smtp-password'),'user':owner.pw_name,'uid':owner.pw_uid,'units':json.loads(units)}
put(config_dir/'weekly-upgrade.json',json.dumps(config,indent=2)+'\\n',0o600)
events=pathlib.Path('/var/lib/server-tooling');events.mkdir(exist_ok=True);events.chmod(0o755)
reports=events/'weekly-upgrade';reports.mkdir(exist_ok=True);reports.chmod(0o700)
if has_tunnel: put('/etc/systemd/system/cloudflared.service.d/50-server-tooling.conf',
 '[Service]\\n# Preserve the default 30s graceful drain; bound a hung shutdown.\\nTimeoutStopSec=40s\\n'
 'ExecStartPost=-/usr/bin/python3 /usr/local/lib/server-tooling/events.py tunnel-start "Cloudflare Tunnel service started"\\n'
 'ExecStopPost=-/usr/bin/python3 /usr/local/lib/server-tooling/events.py tunnel-stop "Cloudflare Tunnel service stopped"\\n')
put('/etc/systemd/system/server-tooling-full-upgrade.service.d/50-report.conf',
 '[Service]\\n# Reporting must not prevent OS updates if the snapshot fails.\\n'
 'ExecStartPre=-/usr/bin/python3 /usr/local/lib/server-tooling/report.py begin\\n'
 'ExecStopPost=/usr/bin/python3 /usr/local/lib/server-tooling/report.py finish\\nTimeoutStopSec=180s\\n')
put('/etc/systemd/system/server-tooling-upgrade-report-retry.service',
 '[Unit]\\nDescription=Retry queued weekly upgrade email reports\\nAfter=network-online.target\\n'
 '[Service]\\nType=oneshot\\nExecStart=/usr/bin/python3 /usr/local/lib/server-tooling/report.py retry\\nTimeoutStartSec=180s\\n')
put('/etc/systemd/system/server-tooling-upgrade-report-retry.timer',
 '[Unit]\\nDescription=Retry upgrade reports every 15 minutes\\n'
 '[Timer]\\nOnBootSec=5m\\nOnUnitActiveSec=15m\\n[Install]\\nWantedBy=timers.target\\n')
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now','server-tooling-upgrade-report-retry.timer'],check=True)
subprocess.run(['/usr/bin/python3',str(root/'events.py'),'import-journal'],check=True)
print('Installed upgrade reports' + (' and 40-second tunnel stop deadline.' if has_tunnel else '.'))
print('Backups:',backup)
'''
        ssh(args.host, ['sudo', '-n', 'python3', '-c', code, remote, info['home'], args.email, args.from_email, args.host.split('@')[-1], json.dumps(units)])
    finally:
        ssh(args.host, ['rm', '-rf', remote])


if __name__ == '__main__':
    main()
