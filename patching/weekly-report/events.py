#!/usr/bin/env python3
"""Root-owned maintenance event journal and bounded Prometheus export."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path('/var/lib/server-tooling')


def record(event, detail, when=None, root=ROOT):
    root.mkdir(mode=0o755, parents=True, exist_ok=True)
    with (root / 'events.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = root / 'events.json'
        now = time.time()
        rows = json.loads(path.read_text()) if path.exists() else []
        row = {'event': event, 'detail': detail[:300], 'time': when if when is not None else now}
        if row not in rows:
            rows.append(row)
        rows = [r for r in rows if r['time'] >= now - 30 * 86400][-1000:]
        atomic(path, json.dumps(rows), 0o644)
        metrics = '# TYPE server_tooling_event_time_seconds gauge\n'
        for r in rows:
            labels = dict(event=r['event'], detail=r['detail'], event_id=str(r['time']))
            labels = ','.join(k + '=' + json.dumps(v, ensure_ascii=False) for k, v in labels.items())
            metrics += f'server_tooling_event_time_seconds{{{labels}}} {r["time"]}\n'
        atomic(root / 'events.prom', metrics, 0o644)


def atomic(path, content, mode=0o600):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(content)
    temporary.chmod(mode)
    temporary.replace(path)


def import_journal():
    """One-time backfill of specific lifecycle messages, never arbitrary log text."""
    marker = ROOT / '.journal-imported'
    if marker.exists():
        return
    patterns = {
        'Starting server-tooling-full-upgrade.service': ('weekly-upgrade', 'Weekly upgrade started (journal)'),
        'Finished server-tooling-full-upgrade.service': ('weekly-upgrade', 'Weekly upgrade completed (journal)'),
        'server-tooling-full-upgrade.service: Failed with result': ('weekly-upgrade', 'Weekly upgrade failed (journal)'),
        'Stopping cloudflared.service': ('tunnel-stop', 'Cloudflare Tunnel stopping (journal)'),
        'Started cloudflared.service': ('tunnel-start', 'Cloudflare Tunnel service started (journal)'),
    }
    result = subprocess.run(['journalctl', '-u', 'server-tooling-full-upgrade.service', '-u', 'cloudflared.service',
                             '--since', '30 days ago', '--no-pager', '-o', 'json'],
                            check=True, capture_output=True, text=True)
    count = 0
    for line in result.stdout.splitlines():
        row = json.loads(line)
        message = row.get('MESSAGE', '')
        if not isinstance(message, str):
            continue
        for prefix, (event, detail) in patterns.items():
            if message.startswith(prefix):
                record(event, detail, int(row['__REALTIME_TIMESTAMP']) / 1_000_000)
                count += 1
                break
    ROOT.mkdir(parents=True, exist_ok=True)
    marker.write_text(str(count))
    print('Imported maintenance lifecycle events:', count)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('event')
    parser.add_argument('detail', nargs='?')
    parser.add_argument('--time', type=float)
    args = parser.parse_args()
    if args.event == 'import-journal':
        import_journal()
        raise SystemExit(0)
    if not args.detail:
        parser.error('detail is required')
    detail = args.detail
    if args.event == 'tunnel-stop':
        detail += ' (result: ' + os.environ.get('SERVICE_RESULT', 'unknown') + ')'
    record(args.event, detail, args.time)
