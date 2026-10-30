#!/usr/bin/env python3
"""Run on Mini after copying this directory. Prepare updater; --enable installs its scheduler."""
import argparse
import fcntl
import os
import platform
import plistlib
import shutil
import subprocess
from pathlib import Path
from updater import ROOT, OLLAMA, Updater


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--enable', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Darwin': raise SystemExit('Mini/macOS only')
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True)
    lock = (ROOT/'update.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('Updater is running; retry installation after it finishes')
    source = Path(__file__).with_name('updater.py')
    if source.resolve() != (ROOT/'updater.py').resolve():
        shutil.copy2(source, ROOT/'updater.py.new')
        (ROOT/'updater.py.new').replace(ROOT/'updater.py')
    current = OLLAMA/'current'
    if not current.exists(): current.symlink_to(OLLAMA/'bin')
    if not current.is_symlink(): raise SystemExit('Managed current link required')
    # Retain the original complete distribution and service configuration for rollback.
    original = ROOT/'original-ollama.plist'
    if not original.exists(): shutil.copy2(Path.home()/'Library/LaunchAgents/com.ollama.server.plist', original)
    updater=Updater()
    updater.tick(check_now=True, install=False)
    if not args.enable:
        print('Prepared; scheduler not enabled. Run updater.py --apply-now for observed first upgrade.')
        return
    logs=Path.home()/'Library/Logs/ollama-updater';logs.mkdir(parents=True,exist_ok=True)
    label='com.server-tooling.ollama-updater'
    plist=Path.home()/f'Library/LaunchAgents/{label}.plist'
    plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':['/usr/bin/python3',str(ROOT/'updater.py')],
        'RunAtLoad':True,'StartInterval':300,'ProcessType':'Background',
        'LimitLoadToSessionType':['Aqua','Background'],
        'StandardOutPath':str(logs/'updater.log'),'StandardErrorPath':str(logs/'updater.error.log')}))
    domain=f'user/{os.getuid()}'
    for name in (f'gui/{os.getuid()}',f'user/{os.getuid()}'):
        if subprocess.run(['/bin/launchctl','print',name],capture_output=True).returncode==0:
            domain=name;break
    for name in (f'gui/{os.getuid()}',f'user/{os.getuid()}'):
        target=name+'/'+label
        if subprocess.run(['/bin/launchctl','print',target],capture_output=True).returncode==0:
            subprocess.run(['/bin/launchctl','bootout',target],check=True,capture_output=True)
    subprocess.run(['/bin/launchctl','bootstrap',domain,str(plist)],check=True)
    print('Enabled: five-minute recovery ticks, daily release checks, Wednesday 12:00–14:00 Europe/London installation window.')


if __name__=='__main__': main()
