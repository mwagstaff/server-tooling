#!/usr/bin/env python3
"""Reboot at the scheduled time, allowing package transactions up to 30 minutes to finish."""
from contextlib import ExitStack
import fcntl
from pathlib import Path
import subprocess
import sys
import time

from events import record

LOCKS = ['/var/lib/dpkg/lock-frontend', '/var/lib/dpkg/lock']


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


def main(required_only=False):
    reason = 'Post-update reboot' if required_only else 'Weekly reboot'
    deadline = time.monotonic() + 30 * 60
    deferred = False
    while True:
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
