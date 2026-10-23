#!/usr/bin/env python3
"""Reboot at the scheduled time, allowing package transactions up to 30 minutes to finish."""
from contextlib import ExitStack
from datetime import datetime
import fcntl
import json
from pathlib import Path
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

from events import record

LOCKS = ['/var/lib/dpkg/lock-frontend', '/var/lib/dpkg/lock']

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


def begin_alert_maintenance():
    config_file = Path('/etc/server-tooling/aiops-maintenance.json')
    if not config_file.exists():
        return
    try:
        config = json.loads(config_file.read_text())
        subprocess.run(['/usr/bin/python3', '/usr/local/lib/server-tooling/alert-maintenance.py',
                        '--state-dir', config['stateDir'], '--host-wide', '--seconds', '600',
                        '--reason', 'Scheduled host reboot'], check=True, timeout=60)
    except Exception:
        record('scheduled-reboot', 'Alert maintenance unavailable; reboot will proceed with monitoring enabled')


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
                subprocess.run(['systemctl', '--check-inhibitors=yes', 'reboot'], check=True)
                return
        if time.monotonic() >= deadline:
            raise RuntimeError('Package installation still active after 30 minutes; reboot skipped')
        time.sleep(30)


if __name__ == '__main__':
    try:
        main(required_only='--if-needed' in sys.argv)
    except Exception as error:
        record('scheduled-reboot', 'Reboot failed or skipped: ' + str(error)[:300])
        raise
