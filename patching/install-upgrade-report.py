#!/usr/bin/env python3
"""Install upgrade reports, host event recording and bounded tunnel shutdown.

Uses the existing weekly upgrade timer and Plunk secret. Does not run an upgrade
or restart the tunnel. Run from the repository: python3 patching/install-upgrade-report.py sky
"""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'monitoring/platform'))
from install import inspect, run, ssh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--email', default='mike.wagstaff@gmail.com')
    args = parser.parse_args()
    info = inspect(args.host)
    if info['os'] != 'linux':
        parser.error('The weekly APT report is for Linux hosts')
    source = Path(__file__).resolve().parent / 'weekly-report'
    inventory = json.loads((source.parents[1] / 'monitoring/platform/inventory.json').read_text())
    units = [service['unit'] + '.service' for service in inventory['hosts'][args.host]['services']]
    remote = ssh(args.host, ['mktemp', '-d'], capture_output=True, text=True).stdout.strip()
    try:
        for name in ['events.py', 'report.py']:
            run(['scp', '-q', source / name, args.host + ':' + remote + '/' + name])
        code = '''import datetime,json,pathlib,pwd,shutil,subprocess,sys
staged,home,email,units=sys.argv[1:]
root=pathlib.Path('/usr/local/lib/server-tooling')
config_dir=pathlib.Path('/etc/server-tooling')
secret=pathlib.Path(home)/'monitoring/secrets/plunk-smtp-password'
subprocess.run(['systemctl','cat','server-tooling-full-upgrade.service'],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['systemctl','cat','cloudflared.service'],check=True,stdout=subprocess.DEVNULL)
if not secret.is_file(): raise SystemExit('Existing Plunk SMTP credential missing')
backup=pathlib.Path('/var/backups/server-tooling')/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
backup.mkdir(parents=True,mode=0o700)
def put(path,text,mode=0o644):
 p=pathlib.Path(path); p.parent.mkdir(parents=True,exist_ok=True)
 if p.exists():
  saved=backup/str(p).lstrip('/'); saved.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,saved)
 temp=p.with_suffix(p.suffix+'.new'); temp.write_text(text); temp.chmod(mode); temp.replace(p)
for name in ['events.py','report.py']:
 put(root/name,(pathlib.Path(staged)/name).read_text(),0o755)
config_dir.mkdir(mode=0o700,exist_ok=True)
put(config_dir/'weekly-upgrade.smtp-password',secret.read_text(),0o600)
owner=pwd.getpwuid(pathlib.Path(home).stat().st_uid)
config={'to':email,'from':'alerts@skynolimit.dev','smtp_host':'next-smtp.useplunk.com','smtp_port':2587,'smtp_user':'plunk',
 'password_file':str(config_dir/'weekly-upgrade.smtp-password'),'user':owner.pw_name,'uid':owner.pw_uid,'units':json.loads(units)}
put(config_dir/'weekly-upgrade.json',json.dumps(config,indent=2)+'\\n',0o600)
events=pathlib.Path('/var/lib/server-tooling');events.mkdir(exist_ok=True);events.chmod(0o755)
reports=events/'weekly-upgrade';reports.mkdir(exist_ok=True);reports.chmod(0o700)
put('/etc/systemd/system/cloudflared.service.d/50-server-tooling.conf',
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
print('Installed report hooks and 40-second tunnel stop deadline. Existing tunnel left running.')
print('Backups:',backup)
'''
        ssh(args.host, ['sudo', '-n', 'python3', '-c', code, remote, info['home'], args.email, json.dumps(units)])
    finally:
        ssh(args.host, ['rm', '-rf', remote])


if __name__ == '__main__':
    main()
