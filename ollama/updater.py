#!/usr/bin/env python3
"""Pinned-policy Ollama updater for Mini. No shell commands or model downloads."""
import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import time
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path.home() / '.local/share/ollama-updater'
OLLAMA = Path.home() / '.local/share/ollama'
API = 'http://127.0.0.1:11434'
WORKER = 'http://127.0.0.1:3310'
RELEASES = 'https://api.github.com/repos/ollama/ollama/releases?per_page=100'
SETTLE_SECONDS = 48 * 3600
DRAIN_SECONDS = 20 * 60
MODEL = 'qwen3.5:9b'


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as handle:
        json.dump(data, handle)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def request(url, data=None, method=None, headers=None, timeout=15):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None,
        method=method, headers={'User-Agent': 'ServerToolingOllamaUpdater/1.0', 'Content-Type': 'application/json', **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def version(text):
    if not isinstance(text, str) or not re.fullmatch(r'v?\d+\.\d+\.\d+', text):
        raise ValueError('Invalid stable version')
    return tuple(map(int, text.lstrip('v').split('.')))


def choose_release(releases, installed, now):
    current = version(installed)
    stable = [r for r in releases if not r.get('prerelease') and not r.get('draft') and
              re.fullmatch(r'v\d+\.\d+\.\d+', r.get('tag_name', ''))]
    latest = max(stable, key=lambda r: version(r['tag_name']), default=None)
    eligible = [r for r in stable if version(r['tag_name'])[:2] == current[:2] and
                version(r['tag_name']) > current and
                now - datetime.fromisoformat(r['published_at'].replace('Z', '+00:00')).timestamp() >= SETTLE_SECONDS]
    return latest, max(eligible, key=lambda r: version(r['tag_name']), default=None)


def install_window(now):
    local = datetime.fromtimestamp(now, ZoneInfo('Europe/London'))
    return local.weekday() == 2 and 12 <= local.hour < 14  # Wednesday, including DST


def extract_verified(archive, destination, digest):
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest or ''):
        raise ValueError('Missing publisher SHA-256')
    h = hashlib.sha256()
    with archive.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''): h.update(chunk)
    if 'sha256:' + h.hexdigest() != digest:
        raise ValueError('Archive checksum mismatch')
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        if sum(m.size for m in members) > 3 * 1024**3:
            raise ValueError('Archive expanded size exceeds limit')
        # Validate every member before extraction; refuse special files and escaping links.
        for m in members:
            if m.name.startswith('/') or '..' in Path(m.name).parts or not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
                raise ValueError('Unsafe archive member')
            if m.issym() or m.islnk():
                target = (destination / (Path(m.name).parent if m.issym() else Path()) / m.linkname).resolve()
                if m.linkname.startswith('/') or destination.resolve() not in target.parents:
                    raise ValueError('Unsafe archive link')
        bundle.extractall(destination)


def validate_stream(lines):
    content, done, count = '', False, 0
    for line in lines:
        count += len(line)
        if count > 1024 * 1024: raise ValueError('Smoke response too large')
        if not line.strip(): continue
        chunk = json.loads(line)
        if chunk.get('error'): raise ValueError('Ollama smoke stream error')
        if done: raise ValueError('Data after stream completion')
        content += chunk.get('message', {}).get('content', '')
        done = chunk.get('done') is True
    if not done: raise ValueError('Incomplete smoke stream')
    result = json.loads(content)
    if result != {'ok': True, 'number': 7}: raise ValueError('Structured smoke result failed')


class Updater:
    def __init__(self, root=ROOT, ollama=OLLAMA):
        self.root, self.ollama = root, ollama
        self.statefile = root / 'state.json'
        self.state = json.loads(self.statefile.read_text()) if self.statefile.exists() else {'phase': 'idle', 'blockedVersions': []}

    def save(self, **values):
        self.state.update(values)
        self.state['updatedAt'] = time.time()
        atomic_json(self.statefile, self.state)

    def event(self, outcome, **values):
        record = {'time': datetime.now(timezone.utc).isoformat(), 'outcome': outcome, **values}
        with (self.root / 'history.jsonl').open('a') as handle: handle.write(json.dumps(record) + '\n')
        print(json.dumps(record), flush=True)

    def installed(self):
        result = request(API + '/api/version')['version']
        version(result)
        return result

    def stage(self, release):
        tag = release['tag_name']
        version(tag)
        asset = next(a for a in release['assets'] if a['name'] == 'ollama-darwin.tgz')
        url = asset['browser_download_url']
        if url != f'https://github.com/ollama/ollama/releases/download/{tag}/ollama-darwin.tgz':
            raise ValueError('Unexpected release asset URL')
        staging = self.root / 'staging'
        staging.mkdir(exist_ok=True)
        archive = staging / f'ollama-{tag}.tgz'
        if not archive.exists():
            tmp = archive.with_suffix('.download')
            with urllib.request.urlopen(url, timeout=120) as source, tmp.open('wb') as target:
                size = 0
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk: break
                    size += len(chunk)
                    if size > 1024**3: raise ValueError('Download exceeds limit')
                    target.write(chunk)
            tmp.replace(archive)
        destination = self.ollama / 'releases' / tag
        if destination.resolve() == (self.ollama / 'current').resolve():
            raise ValueError('Refusing to replace active release')
        if destination.exists(): shutil.rmtree(destination)
        destination.mkdir(parents=True)
        extract_verified(archive, destination, asset.get('digest'))
        binary = destination / 'ollama'
        # Official binaries must remain signed and include Apple Silicon code.
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True, capture_output=True)
        signature = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(binary)], check=True, capture_output=True, text=True).stderr
        if 'TeamIdentifier=3MU9H2V9Y9' not in signature:
            raise ValueError('Ollama signing identity changed; review required')
        architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(binary)], text=True)
        if 'arm64' not in architectures: raise ValueError('Apple Silicon binary missing')
        self.event('staged', version=tag, digest=asset['digest'])
        return destination

    def gate(self, method):
        return request(WORKER + '/maintenance', method=method,
                       headers={'X-Worker-Maintenance': '1', 'X-Maintenance-Owner': self.state['owner']})

    def drain(self):
        self.gate('POST')
        deadline = time.monotonic() + DRAIN_SECONDS
        while time.monotonic() < deadline:
            gate = self.gate('GET')
            if gate.get('owner') != self.state['owner'] or not gate.get('paused'):
                raise RuntimeError('Worker admission gate lost')
            processes = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
            manual = any(re.search(r'(?:^|[ /])run-once\.(?:js|cjs|ts)(?: |$)', line) for line in processes.splitlines())
            connections = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:11434', '-sTCP:ESTABLISHED'], capture_output=True, text=True)
            if connections.returncode not in (0, 1): raise RuntimeError('Cannot verify Ollama connections')
            if gate.get('active') == 0 and not manual and connections.returncode == 1:
                return True
            time.sleep(5)
        return False

    def silence(self):
        import shlex
        base = Path.home() / '.local/share/aiops'
        cfg = json.loads((base / 'config.json').read_text())
        secrets = dict(s.split('=', 1) for s in shlex.split((base / 'secrets.env').read_text(), comments=True) if '=' in s)
        request(cfg['peers']['sky'] + '/api/maintenance',
                {'host': 'mini', 'services': ['kidsplorers-events-worker'], 'seconds': 1800, 'reason': 'Validated Ollama patch upgrade'},
                headers={'Authorization': 'Bearer ' + secrets['AIOPS_PEER_TOKEN']}, timeout=30)

    def switch(self, directory):
        directory = Path(directory).resolve()
        if (directory != (self.ollama / 'bin').resolve() and self.ollama.joinpath('releases').resolve() not in directory.parents) or not (directory / 'ollama').is_file():
            raise ValueError('Unmanaged release path')
        link = self.ollama / 'current'
        if not link.is_symlink(): raise ValueError('Install managed layout before upgrading')
        temporary = self.ollama / 'current.next'
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(directory)
        temporary.replace(link)
        target = None
        for domain in (f'gui/{os.getuid()}', f'user/{os.getuid()}'):
            if subprocess.run(['/bin/launchctl', 'print', domain + '/com.ollama.server'], capture_output=True).returncode == 0:
                target = domain + '/com.ollama.server'
                break
        import plistlib
        plist = Path.home() / 'Library/LaunchAgents/com.ollama.server.plist'
        data = plistlib.loads(plist.read_bytes())
        data['ProgramArguments'] = [str(link / 'ollama'), 'serve']
        tmp = plist.with_suffix('.new')
        tmp.write_bytes(plistlib.dumps(data)); tmp.replace(plist)
        domain = target.rsplit('/', 1)[0] if target else f'user/{os.getuid()}'
        if target:
            subprocess.run(['/bin/launchctl', 'bootout', target], check=True, capture_output=True, timeout=30)
            for _ in range(30):
                if subprocess.run(['/bin/launchctl', 'print', target], capture_output=True).returncode: break
                time.sleep(1)
        subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(plist)], check=True, capture_output=True, timeout=30)

    def smoke(self, expected):
        deadline = time.monotonic() + 90
        while True:
            try:
                if self.installed() == expected.lstrip('v'): break
            except Exception: pass
            if time.monotonic() >= deadline: raise RuntimeError('Expected Ollama version did not start')
            time.sleep(2)
        schema = {'type': 'object', 'properties': {'ok': {'type': 'boolean'}, 'number': {'type': 'integer'}},
                  'required': ['ok', 'number'], 'additionalProperties': False}
        # Repeated shared-prefix requests exercise the MLX cache, not just HTTP readiness.
        for n in range(3):
            body = {'model': MODEL, 'messages': [{'role': 'user', 'content': 'Return exactly {"ok":true,"number":7}. Trial ' + str(n)}],
                    'format': schema, 'think': False, 'stream': True, 'keep_alive': '1m',
                    'options': {'temperature': 0, 'num_ctx': 24576, 'num_predict': 128}}
            req = urllib.request.Request(API + '/api/chat', data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=120) as response: validate_stream(response)
        self.event('smoke_passed', version=expected, requests=3, model=MODEL)

    def release_gate(self):
        self.gate('DELETE')
        self.save(phase='idle', owner=None)

    def recover(self):
        phase = self.state.get('phase', 'idle')
        if phase == 'idle': return
        if phase in ('draining', 'staged'):
            # No binary switch occurred; the previous process may still be busy.
            self.release_gate()
            self.save(lastOutcome='interrupted_before_switch')
            return
        # Always return to the known-good version after an interrupted transaction.
        self.save(phase='rollback')
        self.gate('POST')
        self.switch(self.state['previousDir'])
        self.smoke(self.state['previousVersion'])
        blocked = list(dict.fromkeys(self.state.get('blockedVersions', []) + [self.state['targetVersion']]))[-20:]
        self.save(installedVersion=self.state['previousVersion'], blockedVersions=blocked,
                  lastOutcome='rolled_back', healthError='Upgrade failed or interrupted; previous version restored', phase='resuming')
        self.release_gate()
        self.event('rolled_back', version=self.state['targetVersion'])

    def apply(self, release):
        try:
            target = self.stage(release)
        except Exception:
            self.save(blockedVersions=list(dict.fromkeys(self.state.get('blockedVersions', []) + [release['tag_name']]))[-20:])
            raise
        self.save(phase='draining', owner=str(uuid.uuid4()), previousDir=str((self.ollama / 'current').resolve()),
                  previousVersion=self.state['installedVersion'], targetVersion=release['tag_name'], targetDir=str(target), transactionStartedAt=time.time())
        try:
            if not self.drain():
                self.release_gate()
                self.save(lastOutcome='deferred_busy', deferredSince=self.state.get('deferredSince') or time.time())
                self.event('deferred_busy')
                return
            self.silence()  # If the owner cannot record maintenance, defer without switching.
            self.save(phase='switching')
            self.switch(target)
            self.save(phase='validating')
            self.smoke(release['tag_name'])
            # Persist validation before resuming; a crash before commit safely rolls back.
            self.save(installedVersion=release['tag_name'].lstrip('v'), lastUpgradeAt=time.time(),
                      lastOutcome='upgraded', healthError=None, deferredSince=None, phase='committed')
            self.release_gate()
            self.event('upgraded', version=release['tag_name'])
        except Exception as exc:
            self.save(healthError=type(exc).__name__ + ': ' + str(exc)[:300], lastOutcome='failed')
            if self.state.get('phase') == 'draining':
                self.release_gate()
            else:
                self.recover()
            raise

    def tick(self, apply_now=False, check_now=False, install=True):
        if self.state.get('phase', 'idle') == 'committed':
            # A validated transaction only needs its gate released, never an unnecessary rollback.
            try:
                self.smoke(self.state['installedVersion'])
                self.release_gate()
            except Exception:
                self.recover()
                raise
        else: self.recover()
        now = time.time()
        if check_now or apply_now or now - self.state.get('lastCheckAt', 0) >= 86400:
            installed = self.installed()
            try: releases = request(RELEASES, timeout=45)
            except Exception:
                self.save(lastOutcome='check_failed')
                raise
            if self.state.get('lastOutcome') == 'check_failed':
                self.save(healthError=None, lastOutcome='checked')
            latest, candidate = choose_release(releases, installed, now)
            pending = bool(latest and version(latest['tag_name']) > version(installed))
            self.save(installedVersion=installed, latestVersion=latest['tag_name'].lstrip('v') if latest else installed,
                      lastCheckAt=now, candidate=candidate, pendingSince=(self.state.get('pendingSince') or now) if pending else None,
                      reviewRequired=bool(latest and version(latest['tag_name'])[:2] != version(installed)[:2]))
        candidate = self.state.get('candidate')
        if install and candidate and (apply_now or install_window(now)) and version(candidate['tag_name']) > version(self.state['installedVersion']):
            if candidate['tag_name'] in self.state.get('blockedVersions', []): return
            if self.installed() != self.state['installedVersion']:
                raise RuntimeError('Installed version changed outside updater; fresh check required')
            self.apply(candidate)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply-now', action='store_true', help='Bypass weekly window, never release age or patch policy')
    parser.add_argument('--check-now', action='store_true')
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.umask(0o077)
    with (ROOT / 'update.lock').open('w') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        updater = Updater()
        try: updater.tick(args.apply_now, args.check_now)
        except Exception as exc:
            updater.save(healthError=type(exc).__name__ + ': ' + str(exc)[:300])
            updater.event('failed', error=type(exc).__name__ + ': ' + str(exc)[:300])
            raise SystemExit(1)


if __name__ == '__main__': main()
