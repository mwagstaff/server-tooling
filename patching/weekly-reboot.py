#!/usr/bin/env python3
"""Reboot at the scheduled time, allowing package transactions up to 30 minutes to finish."""
from contextlib import ExitStack
import fcntl
import subprocess
import time

from events import record

LOCKS = ['/var/lib/dpkg/lock-frontend', '/var/lib/dpkg/lock']


def main():
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
                    record('scheduled-reboot', 'Weekly reboot delayed: package installation in progress (maximum 30 minutes)')
                    deferred = True
            else:
                record('scheduled-reboot', 'Weekly reboot requested (Saturday 04:00 Europe/London schedule)')
                subprocess.run(['systemctl', '--check-inhibitors=yes', 'reboot'], check=True)
                return
        if time.monotonic() >= deadline:
            raise RuntimeError('Package installation still active after 30 minutes; weekly reboot skipped')
        time.sleep(30)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        record('scheduled-reboot', 'Weekly reboot failed or skipped: ' + str(error)[:300])
        raise
