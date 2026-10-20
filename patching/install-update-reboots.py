#!/usr/bin/env python3
"""Enable conditional reboots after successful Ubuntu maintenance, without running it."""
import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'monitoring/platform'))
from install import run, ssh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@-]*', args.host):
        parser.error('Use an SSH host alias or user@hostname')
    ssh(args.host, ['sudo', '-n', 'true'])
    stage = ssh(args.host, ['mktemp', '-d'], capture_output=True, text=True).stdout.strip()
    try:
        run(['scp', '-q', Path(__file__).with_name('weekly-reboot.py'), args.host + ':' + stage + '/weekly-reboot.py'])
        code = '''import datetime,pathlib,shutil,subprocess,sys
root=pathlib.Path('/etc/systemd/system')
units=['apt-daily-upgrade.service','server-tooling-full-upgrade.service']
for unit in units:
 subprocess.run(['systemctl','cat',unit],check=True,stdout=subprocess.DEVNULL)
if not pathlib.Path('/usr/local/lib/server-tooling/events.py').is_file():
 raise SystemExit('Install host maintenance and reports first')
backup=pathlib.Path('/var/backups/server-tooling')/('update-reboots-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
backup.mkdir(parents=True,mode=0o700)
def put(path,text,mode=0o644):
 path=pathlib.Path(path)
 if path.exists() and path.read_text()==text: return
 if path.exists():
  saved=backup/str(path).lstrip('/'); saved.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(path,saved)
 path.parent.mkdir(parents=True,exist_ok=True)
 temp=path.with_suffix(path.suffix+'.new'); temp.write_text(text); temp.chmod(mode); temp.replace(path)
put('/usr/local/lib/server-tooling/weekly-reboot.py',pathlib.Path(sys.argv[1]).read_text(),0o755)
put(root/'server-tooling-update-reboot.service',
 '[Unit]\\nDescription=Reboot when required within 04:00-05:00 UK time\\n'
 'After=apt-daily-upgrade.service server-tooling-full-upgrade.service\\n'
 '[Service]\\nType=oneshot\\n'
 'ExecStart=/usr/bin/python3 /usr/local/lib/server-tooling/weekly-reboot.py --if-needed\\n'
 'TimeoutStartSec=35min\\n')
put(root/'server-tooling-update-reboot.timer',
 '[Unit]\\nDescription=Check pending update reboots daily at 04:00 UK time\\n'
 '[Timer]\\nOnCalendar=*-*-* 04:00:00 Europe/London\\n'
 'AccuracySec=1s\\nRandomizedDelaySec=0\\nPersistent=false\\n'
 '[Install]\\nWantedBy=timers.target\\n')
for unit in units:
 put(root/(unit+'.d')/'60-reboot.conf','[Unit]\\nOnSuccess=server-tooling-update-reboot.service\\n')
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemd-analyze','verify',str(root/'server-tooling-update-reboot.service'),str(root/'server-tooling-update-reboot.timer'),*units],check=True)
subprocess.run(['systemctl','enable','--now','server-tooling-update-reboot.timer'],check=True)
subprocess.run(['systemctl','restart','server-tooling-update-reboot.timer'],check=True)
print('Conditional reboots restricted to 04:00-05:00 UK time; daily 04:00 check enabled. No update or reboot was run. Backups:',backup)
'''
        ssh(args.host, ['sudo', '-n', 'python3', '-c', code, stage + '/weekly-reboot.py'])
    finally:
        ssh(args.host, ['rm', '-rf', stage])


if __name__ == '__main__':
    main()
