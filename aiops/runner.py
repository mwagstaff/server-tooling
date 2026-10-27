#!/usr/bin/env python3
"""Restricted SSH entry point. Accept one JSON request; never evaluate a shell."""
import contextlib
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

ROOT = Path(os.environ.get('AIOPS_STATE_DIR', str(Path.home() / '.local/share/aiops')))


def command(args, timeout=15):
    result = subprocess.run(args, capture_output=True, timeout=timeout, text=True,
                            env={**os.environ, 'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'})
    return {'code': result.returncode, 'stdout': result.stdout[-12000:], 'stderr': result.stderr[-2000:]}


def clean(text):
    text = re.sub(r'(?i)(mongodb(?:\+srv)?://|https?://)[^\s/"@]+:[^\s/"@]+@', r'\1[redacted]@', text)
    text = re.sub(r'(?i)((?:authorization|api[_-]?key|password|secret|access[_-]?token|cookie)\s*["\']?\s*[:=]\s*["\']?)(?:Bearer\s+|Token\s+)?[^"\'\s,;}]+', r'\1[redacted]', text)
    text = re.sub(r'\bsk-[\w-]{12,}\b', '[token redacted]', text)
    text = re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email redacted]', text)
    return text


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def probe(url, user_agent=None):
    try:
        if user_agent:
            url = urllib.request.Request(url, headers={'User-Agent': user_agent})
        deadline = time.monotonic() + 8
        with urllib.request.build_opener(NoRedirect).open(url, timeout=8) as response:
            # Drain streamed pages: closing after headers creates false abort errors.
            size = 0
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                size += len(chunk)
                if size > 8 * 1024 * 1024 or time.monotonic() > deadline:
                    return {'ok': False, 'error': 'ResponseLimitExceeded'}
            expected = response.headers.get('Content-Length')
            if expected is not None and size != int(expected):
                return {'ok': False, 'error': 'IncompleteResponse'}
            return {'ok': 200 <= response.status < 300, 'status': response.status}
    except Exception as exc:
        return {'ok': False, 'error': type(exc).__name__}


def launchd_service(item):
    # Headless Macs can load LaunchAgents in user/<uid> without a GUI session.
    domains = ['system'] if item.get('scope') == 'system' else [f'gui/{os.getuid()}', f'user/{os.getuid()}']
    for domain in domains:
        target = domain + '/' + item['unit']
        result = command(['launchctl', 'print', target])
        if result['code'] == 0:
            return target, result
    return None, result


def status(item):
    if platform.system() == 'Linux':
        r = command(['systemctl', '--user', 'is-active', item['unit'] + '.service'])
        return {'active': r['code'] == 0, 'state': r['stdout'].strip()}
    _, r = launchd_service(item)
    return {'active': r['code'] == 0 and 'state = running' in r['stdout'],
            'state': 'running' if 'state = running' in r['stdout'] else 'not running'}


def event_logs(text, source):
    """Trust only explicit UTC event times, never a file's mtime or collection time."""
    result = []
    for line in text.splitlines():
        match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z) ', line)
        if not match:
            continue
        try:
            datetime.fromisoformat(match[1].replace('Z', '+00:00'))
        except ValueError:
            continue
        result.append({'at': match[1], 'source': source, 'timestampSource': 'application', 'line': clean(line)[:500]})
    return result[-30:]


def planner_ingestion_evidence():
    path = Path.home() / '.local/share/train-track-planner/planner/ingestion-state.json'
    try:
        with path.open('rb') as handle:
            data = json.loads(handle.read(2 * 1024 * 1024))
        keys = ('schemaVersion', 'enabled', 'inProgress', 'lastCheckAt', 'lastFinishedAt',
                'lastSuccessfulCheckAt', 'lastSuccessAt', 'lastActivatedAt', 'lastResult',
                'lastErrorCode', 'lastErrorMessage', 'phase', 'lastDurationMs', 'pendingGap')
        result = {key: data.get(key) for key in keys}
        active = data.get('active') or {}
        result['active'] = {key: active.get(key) for key in ('version', 'activatedAt', 'baselineSequence', 'currentSequence')}
        result['observedAt'] = datetime.now(timezone.utc).isoformat()
        # Bound and redact even operator-edited state; omit timetable contents/paths.
        return json.loads(clean(json.dumps(result)))
    except (OSError, ValueError, TypeError):
        return {'error': 'Ingestion state unavailable or invalid'}


def inspect(item):
    if item is None:
        return {'host': platform.node(), 'disk': shutil.disk_usage(Path.home())._asdict(),
                'load': os.getloadavg(), 'healthy': None}
    state = status(item)
    health = probe(item['healthUrl'])
    logs = {}
    log_metadata = {}
    events = []
    for name in item.get('logs', []):
        path = Path(name).expanduser()
        try:
            with path.open('rb') as handle:
                stat = path.stat()
                log_metadata[path.name] = {'modifiedAt': datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(), 'timestamped': False}
                handle.seek(max(0, stat.st_size - 14000))
                logs[path.name] = clean(handle.read(14000).decode(errors='replace'))
                events.extend(event_logs(logs[path.name], path.name))
        except OSError:
            logs[path.name] = 'Unavailable'
    dependencies = {name: probe(url) for name, url in item.get('dependencyProbes', {}).items()}
    release = ROOT / 'releases' / item['group'] / 'manifest.json'
    return {'service': item['name'], 'status': state, 'health': health,
            'healthy': state['active'] and health['ok'], 'logs': logs, 'logMetadata': log_metadata,
            'eventLogs': sorted(events, key=lambda row: row['at'])[-30:],
            **({'plannerIngestion': planner_ingestion_evidence()} if item['name'] == 'train-track-planner' else {}),
            'dependencies': dependencies, 'disk': shutil.disk_usage(item['directory'])._asdict(),
            'load': os.getloadavg(), 'releaseAvailable': release.is_file(),
            'retryAvailable': bool(item.get('retryCommand'))}


def service_health(item):
    """Read-only dashboard checks, without collecting logs or invoking recovery."""
    checked = datetime.now(timezone.utc).isoformat()
    try:
        checks = {'process': status(item)['active'], 'endpoint': probe(item['healthUrl'])['ok']}
        if item.get('publicUrl'):
            checks['public'] = probe(item['publicUrl'], 'ServerToolingMonitoring/1.0')['ok']
        if item['name'] == 'kidsplorers-events-worker':
            with urllib.request.build_opener(NoRedirect).open(item['healthUrl'], timeout=8) as response:
                data = json.loads(response.read(65536))
            checks.update(worker_health(data))
        return {'name': item['name'], 'status': 'healthy' if all(checks.values()) else 'unhealthy',
                'checkedAt': checked, 'checks': checks}
    except Exception:
        return {'name': item['name'], 'status': 'unknown', 'checkedAt': checked, 'checks': {}}


def worker_health(data):
    # The worker's lastRun is in memory. Preserve observed results across restarts.
    path = ROOT / 'worker-last-run.json'
    if isinstance(data.get('lastRun'), dict):
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(data['lastRun']))
        temporary.replace(path)
    elif path.exists():
        data = {**data, 'lastRun': json.loads(path.read_text())}
    return worker_checks(data)


def worker_checks(data, now=None):
    """A live HTTP server does not prove that the daily ingestion job succeeded."""
    now = now or datetime.now(timezone.utc)
    last = data.get('lastRun') or {}
    try:
        age = (now - datetime.fromisoformat(last['startedAt'].replace('Z', '+00:00'))).total_seconds()
    except (KeyError, TypeError, ValueError):
        age = float('inf')
    running = data.get('running') is True
    return {'dailyJobRecent': 0 <= age < 28 * 3600,
            'dailyJobCompleted': age < 4 * 3600 if running else bool(last.get('finishedAt')),
            'dailyJobSucceeded': running or (last.get('failed') == 0 and last.get('ok', 0) > 0)}


def restart(item):
    if platform.system() == 'Linux':
        return command(['systemctl', '--user', 'restart', item['unit'] + '.service'], 90)
    if item.get('scope') == 'system':
        return command(['sudo', '-n', item['adminHelper'], 'restart', item['unit']], 90)
    target, _ = launchd_service(item)
    if target is None:
        raise ValueError('Service is not loaded in a registered launchd domain')
    return command(['launchctl', 'kickstart', '-k', target], 90)


def safe_relative(name):
    path = Path(name)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise ValueError('Invalid release path')
    if any(p.startswith('.') or p in ('node_modules', 'certs', 'data', 'logs', 'var', 'resources') for p in path.parts):
        raise ValueError('Persistent or private file cannot be restored')
    if path.suffix not in ('.js', '.mjs', '.cjs', '.json', '.html', '.css', '.svg'):
        raise ValueError('Unsupported release file')
    return path


def restore(item):
    base = ROOT / 'releases' / item['group']
    manifest = json.loads((base / 'manifest.json').read_text())
    directory = Path(item['directory']).resolve()
    if manifest['directory'] != str(directory):
        raise ValueError('Release directory mismatch')
    for name, digest in manifest.get('dependencies', {}).items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Dependency manifest changed; prepare a new reviewed release')
    # Verify the whole release and all destinations before writing anything.
    for name, digest in manifest['files'].items():
        rel = safe_relative(name)
        source, destination = base / 'files' / rel, directory / rel
        if source.is_symlink() or directory not in destination.resolve().parents:
            raise ValueError('Unsafe release path')
        if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise ValueError('Release checksum mismatch')
    for name in manifest['files']:
        rel = safe_relative(name)
        destination = directory / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + '.aiops-new')
        if temporary.exists() or temporary.is_symlink():
            raise ValueError('Release staging file exists')
        shutil.copyfile(base / 'files' / rel, temporary)
        temporary.replace(destination)
    return restart(item)


def handle(request, config):
    operation = request.get('operation')
    name = request.get('service')
    if name == '__host__' and operation == 'health_all':
        with ThreadPoolExecutor(max_workers=16) as pool:
            return {'services': list(pool.map(service_health, config['services']))}
    item = next((s for s in config['services'] if s['name'] == name), None)
    if not item and not (name == '__host__' and operation == 'inspect'):
        raise ValueError('Unregistered service')
    if operation == 'inspect':
        return inspect(item)
    if operation not in ('restart', 'retry', 'redeploy'):
        raise ValueError('Unregistered operation')
    if platform.system() == 'Linux':
        # The existing weekly upgrade owns package/service maintenance. Observe its
        # systemd state without requiring access to its root-only report files.
        for unit in config.get('maintenanceUnits', ['server-tooling-full-upgrade.service','server-tooling-weekly-reboot.service']):
            if command(['systemctl', 'is-active', '--quiet', unit])['code'] == 0:
                return {'ok': False, 'reason': 'Scheduled host maintenance is active'}
    permitted = item.get('autoActions', [])
    if request.get('approved') is True:
        permitted = permitted + item.get('approvalActions', [])
    if operation not in permitted:
        raise ValueError('Action is not permitted')
    action_id = request.get('actionId', '')
    if not re.fullmatch(r'[a-zA-Z0-9_-]{10,100}', action_id):
        raise ValueError('Invalid action ID')
    if operation == 'retry' and not item.get('retryCommand'):
        raise ValueError('No reviewed retry procedure')
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (ROOT / (item['group'] + '.lock')).open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'ok': False, 'reason': 'Another action is running for this project'}
        with contextlib.closing(sqlite3.connect(ROOT / 'actions.sqlite')) as db:
            db.execute('CREATE TABLE IF NOT EXISTS actions(id TEXT PRIMARY KEY, service TEXT, at REAL, result TEXT)')
            previous = db.execute('SELECT result FROM actions WHERE id=?', (action_id,)).fetchone()
            if previous:
                return json.loads(previous[0]) if previous[0] else {'ok': False, 'reason': 'Prior execution outcome unknown; manual review required'}
            if (ROOT / 'PAUSED').exists() or (ROOT / ('PAUSED-' + name)).exists():
                return {'ok': False, 'reason': 'Target recovery is paused'}
            recent = db.execute('SELECT COUNT(*) FROM actions WHERE service=? AND at>?',
                                (name, time.time() - config.get('cooldownSeconds', 900))).fetchone()[0]
            if recent:
                return {'ok': False, 'reason': 'Service recovery cooldown'}
            if any(not probe(url)['ok'] for url in item.get('dependencyProbes', {}).values()):
                return {'ok': False, 'reason': 'Dependency unhealthy'}
            if inspect(item)['healthy'] and request.get('allowHealthy') is not True:
                return {'ok': False, 'reason': 'Service is already healthy'}
            db.execute('INSERT INTO actions VALUES(?,?,?,NULL)', (action_id, name, time.time()))
            db.commit()  # Crash after this point must never replay an uncertain mutation.
            if operation == 'restart':
                result = restart(item)
            elif operation == 'redeploy':
                result = restore(item)
            else:
                # Operator-owned configuration only; no arguments from an alert or model.
                result = command(item['retryCommand'], 90)
            response = {'ok': result['code'] == 0, 'operation': operation, 'result': clean(json.dumps(result))}
            db.execute('UPDATE actions SET result=? WHERE id=?', (json.dumps(response), action_id))
            db.commit()
            return response


if __name__ == '__main__':
    os.umask(0o077)
    try:
        data = sys.stdin.buffer.read(16385)
        if len(data) > 16384:
            raise ValueError('Request too large')
        config = json.loads((ROOT / 'runner.json').read_text())
        print(json.dumps(handle(json.loads(data), config)))
    except Exception as error:
        print(json.dumps({'ok': False, 'error': clean(str(error))[:500]}))
