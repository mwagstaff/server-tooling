#!/usr/bin/env python3
"""Configure official signed Caddy stable packages and daily automatic updates.

Stages and validates the candidate; pass --apply to install it after preflight.
The existing configuration is backed up and preserved.
"""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'monitoring/platform'))
from install import run, ssh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    remote = ssh(args.host, ['mktemp', '-d'], capture_output=True, text=True).stdout.strip()
    try:
        run(['scp', '-q', Path(__file__).with_name('validate-caddy-update.py'), args.host + ':' + remote + '/validate-caddy-update.py'])
        code = '''import datetime,json,os,pathlib,shutil,subprocess,sys,urllib.request
staged,apply=sys.argv[1:]
def run(args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def output(args):return subprocess.check_output(args,text=True).strip()
backup=pathlib.Path('/var/backups/server-tooling/caddy-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
backup.mkdir(parents=True,mode=0o700)
shutil.copytree('/etc/caddy',backup/'caddy-config')
shutil.copy2('/usr/bin/caddy',backup/'caddy-binary')
def put(path,data,mode=0o644):
 p=pathlib.Path(path);p.parent.mkdir(parents=True,exist_ok=True)
 if p.exists():
  saved=backup/str(p).lstrip('/');saved.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,saved)
 temp=p.with_suffix(p.suffix+'.new');temp.write_bytes(data if isinstance(data,bytes) else data.encode());temp.chmod(mode);temp.replace(p)
key=urllib.request.urlopen('https://dl.cloudsmith.io/public/caddy/stable/gpg.key',timeout=30).read()
check=subprocess.run(['gpg','--show-keys','--with-colons'],input=key,capture_output=True,check=True).stdout.decode()
fingerprint=next(line.split(':')[9] for line in check.splitlines() if line.startswith('fpr:'))
if fingerprint!='65760C51EDEA2017CEA2CA15155B6D79CA56EA34':raise SystemExit('Caddy signing key changed; review before trusting it')
dearmored=subprocess.run(['gpg','--dearmor'],input=key,capture_output=True,check=True).stdout
put('/usr/share/keyrings/caddy-stable-archive-keyring.gpg',dearmored)
put('/etc/apt/sources.list.d/caddy-stable.list',
 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\\n')
# The new repository may supply Caddy only, not replacement system packages.
put('/etc/apt/preferences.d/server-tooling-caddy',
 'Package: caddy\\nPin: origin dl.cloudsmith.io\\nPin-Priority: 600\\n\\nPackage: *\\nPin: origin dl.cloudsmith.io\\nPin-Priority: -1\\n')
put('/usr/local/lib/server-tooling/validate-caddy-update.py',(pathlib.Path(staged)/'validate-caddy-update.py').read_bytes(),0o755)
put('/etc/apt/apt.conf.d/59-server-tooling-caddy',
 'Unattended-Upgrade::Origins-Pattern:: "site=dl.cloudsmith.io";\\n'
 'DPkg::Pre-Install-Pkgs:: "/usr/bin/python3 /usr/local/lib/server-tooling/validate-caddy-update.py";\\n')
run(['apt-get','-o','APT::Update::Error-Mode=any','update'])
import apt
cache=apt.Cache();package=cache['caddy'];candidate=package.candidate;previous=package.installed.version
if not any(origin.site=='dl.cloudsmith.io' for origin in candidate.origins):raise SystemExit('Caddy candidate is not from the official stable repository')
print('Caddy installed:',package.installed.version,'candidate:',candidate.version)
# Keep the current package for rollback as well as the config and executable.
run(['apt-get','download','caddy='+package.installed.version],cwd=backup)
package_path=pathlib.Path(candidate.fetch_binary(destdir=str(backup)))
run(['/usr/bin/python3','/usr/local/lib/server-tooling/validate-caddy-update.py'],input=str(package_path)+'\\n',text=True)
print('Backup and candidate:',backup)
if apply=='yes':
 env=os.environ.copy();env.update(DEBIAN_FRONTEND='noninteractive',NEEDRESTART_MODE='l')
 run(['apt-get','-y','-o','Dpkg::Options::=--force-confdef','-o','Dpkg::Options::=--force-confold',
      'install','--only-upgrade','caddy='+candidate.version],env=env)
 # Ensure the running process uses the new binary, even if packaging only reloads.
 pid=output(['systemctl','show','caddy','--property=MainPID','--value'])
 if pid=='0' or not os.path.samefile('/proc/'+pid+'/exe','/usr/bin/caddy'):
  run(['systemctl','restart','caddy'])
 run(['systemctl','is-active','--quiet','caddy'])
 print('Running Caddy:',output(['/usr/bin/caddy','version']))
 events=pathlib.Path('/usr/local/lib/server-tooling/events.py')
 if events.exists() and previous!=candidate.version:run(['/usr/bin/python3',str(events),'caddy-upgrade','Caddy upgraded to '+candidate.version+'; official stable automatic updates enabled'])
print('Daily Caddy updates enabled through existing unattended-upgrades; candidate preflight runs before each install.')
'''
        ssh(args.host, ['sudo', '-n', 'python3', '-c', code, remote, 'yes' if args.apply else 'no'])
    finally:
        ssh(args.host, ['rm', '-rf', remote])


if __name__ == '__main__':
    main()
