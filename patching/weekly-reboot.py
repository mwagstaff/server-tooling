#!/usr/bin/env python3
"""Reboot at the scheduled time, allowing package transactions up to 30 minutes to finish."""
from contextlib import ExitStack
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

from events import record

LOCKS = ['/var/lib/dpkg/lock-frontend', '/var/lib/dpkg/lock']
CONTAINERD_PROCS = Path('/sys/fs/cgroup/system.slice/containerd.service/cgroup.procs')

def in_reboot_window(now=None):
    """Keep every automatic reboot inside 04:00–05:00 UK time, including DST."""
    local = (now or datetime.now(ZoneInfo('Europe/London'))).astimezone(ZoneInfo('Europe/London'))
    return local.hour == 4


def reboot_needed():
    if Path('/run/reboot-required').exists():
        return True
    result = subprocess.run(['needrestart', '-b', '-r', 'l'], check=True,
                            capture_output=True, text=True, timeout=120)
    for line in result.stdout.splitlines():
        key, _, value = line.partition(':')
        if key in ('NEEDRESTART-SVC', 'NEEDRESTART-SESS', 'NEEDRESTART-CONT') and value.strip():
            return True
        if key == 'NEEDRESTART-KSTA' and value.strip() in ('2', '3'):
            return True
        if key == 'NEEDRESTART-UCSTA' and value.strip() == '2':
            return True
    return False


def outdated_services():
    result = subprocess.run(['needrestart', '-b', '-r', 'l'], check=True,
                            capture_output=True, text=True, timeout=120)
    return [value.strip() for key, _, value in (line.partition(':') for line in result.stdout.splitlines())
            if key == 'NEEDRESTART-SVC' and value.strip()]


def stale_containers():
    """Docker containers whose containerd shim still runs a replaced binary.

    containerd uses KillMode=process, so its per-container shims survive a containerd
    restart and keep needrestart reporting containerd.service until the container restarts.
    """
    ids = []
    if not CONTAINERD_PROCS.exists():
        return ids
    for pid in CONTAINERD_PROCS.read_text().split():
        try:
            exe = os.readlink(f'/proc/{pid}/exe')
            args = Path(f'/proc/{pid}/cmdline').read_text().split('\0')
        except OSError:
            continue
        if exe.endswith(' (deleted)') and 'moby' in args and '-id' in args:
            ids.append(args[args.index('-id') + 1])
    return ids


def restart_services():
    """After an upgrade, finish the restarts that needrestart's own pass leaves outstanding.

    needrestart already restarts the services it considers safe. Anything else it reports
    (dbus, sessions, kernel) is left for the 04:00-05:00 conditional reboot.
    """
    if 'containerd.service' not in outdated_services():
        return
    begin_alert_maintenance(300, 'Post-upgrade service restarts')
    subprocess.run(['systemctl', 'restart', 'containerd.service'], check=True, timeout=300)
    containers = stale_containers()
    for container in containers:
        subprocess.run(['docker', 'restart', container], check=True, capture_output=True, timeout=300)
    record('weekly-upgrade', f'Restarted containerd.service and {len(containers)} container(s) on outdated shims')


def begin_alert_maintenance(seconds=600, reason='Scheduled host reboot'):
    config_file = Path('/etc/server-tooling/aiops-maintenance.json')
    if not config_file.exists():
        return
    try:
        config = json.loads(config_file.read_text())
        subprocess.run(['/usr/bin/python3', '/usr/local/lib/server-tooling/alert-maintenance.py',
                        '--state-dir', config['stateDir'], '--host-wide', '--seconds', str(seconds),
                        '--reason', reason], check=True, timeout=60)
    except Exception:
        record('scheduled-reboot', reason + ': alert maintenance unavailable; proceeding with monitoring enabled')


def main(required_only=False):
    reason = 'Post-update reboot' if required_only else 'Weekly reboot'
    deadline = time.monotonic() + 30 * 60
    deferred = False
    while True:
        if not in_reboot_window():
            record('scheduled-reboot', reason + ' deferred: outside 04:00–05:00 Europe/London; next check at 04:00')
            return
        with ExitStack() as stack:
            try:
                for name in LOCKS:
                    handle = stack.enter_context(open(name, 'a'))
                    fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if not deferred:
                    record('scheduled-reboot', reason + ' delayed: package installation in progress (maximum 30 minutes)')
                    deferred = True
            else:
                if required_only and not reboot_needed():
                    return
                # Assessments and package lock waits may cross the window boundary.
                if not in_reboot_window():
                    record('scheduled-reboot', reason + ' deferred: maintenance window ended; next check at 04:00')
                    return
                begin_alert_maintenance()
                if not in_reboot_window():
                    record('scheduled-reboot', reason + ' deferred: maintenance window ended')
                    return
                record('scheduled-reboot', reason + ' requested')
                try:
                    subprocess.run(['systemctl', '--check-inhibitors=yes', 'reboot'], check=True, capture_output=True, text=True)
                except subprocess.CalledProcessError as error:
                    detail = (error.stderr or '') + (error.stdout or '')
                    if 'Please retry operation after closing inhibitors and logging out other users' not in detail:
                        raise
                    record('scheduled-reboot', reason + ' deferred: active sessions or inhibitors; next scheduled check will retry')
                return
        if time.monotonic() >= deadline:
            raise RuntimeError('Package installation still active after 30 minutes; reboot skipped')
        time.sleep(30)


if __name__ == '__main__':
    if '--restart-services' in sys.argv:
        try:
            restart_services()
        except Exception as error:
            record('weekly-upgrade', 'Post-upgrade service restarts failed: ' + str(error)[:300])
            raise
        sys.exit()
    try:
        main(required_only='--if-needed' in sys.argv)
    except Exception as error:
        record('scheduled-reboot', 'Reboot failed or skipped: ' + str(error)[:300])
        raise
