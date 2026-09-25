#!/usr/bin/env python3
"""Install the platform locally on a monitored or monitoring host."""
import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

from config import render, write_json

VERSIONS = {'prometheus': '3.15.0', 'alertmanager': '0.34.1', 'node_exporter': '1.12.1', 'blackbox_exporter': '0.28.0'}
ROOT = Path.home() / '.local/share/server-tooling-monitoring'
SOURCE = Path(__file__).resolve().parent


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def binary(name):
    version = VERSIONS[name]
    system = platform.system().lower()
    arch = {'x86_64': 'amd64', 'arm64': 'arm64', 'aarch64': 'arm64'}[platform.machine()]
    folder = f'{name}-{version}.{system}-{arch}'
    destination = ROOT / 'bin' / folder
    if (destination / name).exists():
        return destination / name
    url = f'https://github.com/prometheus/{name}/releases/download/v{version}/'
    print(f'Installing {name} {version}', flush=True)
    with tempfile.TemporaryDirectory() as work:
        archive = Path(work) / (folder + '.tar.gz')
        urllib.request.urlretrieve(url + archive.name, archive)
        checksums = urllib.request.urlopen(url + 'sha256sums.txt', timeout=30).read().decode()
        expected = next(line.split()[0] for line in checksums.splitlines() if line.split()[-1].lstrip('*') == archive.name)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Release checksum mismatch: ' + name)
        with tarfile.open(archive) as bundle:
            bundle.extractall(work, filter='data')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(Path(work) / folder), destination)
    return destination / name


def service(name, argv):
    label = 'com.server-tooling.monitoring.' + name
    log = ROOT / 'logs' / (name + '.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    if platform.system() == 'Darwin':
        plist = {'Label': label, 'ProgramArguments': [str(a) for a in argv], 'RunAtLoad': True,
                 'KeepAlive': True, 'ThrottleInterval': 10, 'WorkingDirectory': str(ROOT),
                 'StandardOutPath': str(log), 'StandardErrorPath': str(log),
                 'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'}}
        system_file = Path('/Library/LaunchDaemons') / (label + '.plist')
        # A root-installed, reviewed helper is deliberately not assumed.
        if system_file.exists():
            current = plist.copy()
            current['UserName'] = os.environ['USER']
            staged = ROOT / (label + '.plist')
            staged.write_bytes(plistlib.dumps(current))
            installed = plistlib.loads(system_file.read_bytes())
            if installed['ProgramArguments'] != current['ProgramArguments']:
                raise RuntimeError('Boot service executable changed. Apply staged update with enable-boot.sh: ' + label)
            # The daemon runs as this user; restarting its process needs no privilege.
            # launchd's KeepAlive starts it again with the same reviewed arguments.
            state = subprocess.check_output(['launchctl', 'print', 'system/' + label], text=True)
            match = re.search(r'^\s*pid = (\d+)$', state, re.M)
            if match:
                os.kill(int(match[1]), signal.SIGHUP if name in ('prometheus', 'alertmanager', 'blackbox') else signal.SIGTERM)
            else:
                raise RuntimeError('Boot service is not running: ' + label)
            return
        path = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
        path.parent.mkdir(parents=True, exist_ok=True)
        previous = plistlib.loads(path.read_bytes()) if path.exists() else None
        path.write_bytes(plistlib.dumps(plist))
        domain = f'gui/{os.getuid()}'
        if subprocess.run(['launchctl', 'print', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            domain = f'user/{os.getuid()}'
        loaded = subprocess.run(['launchctl', 'print', domain + '/' + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if loaded and previous == plist:
            if name in ('prometheus', 'alertmanager', 'blackbox'):
                run(['launchctl', 'kill', 'SIGHUP', domain + '/' + label])
            else:
                run(['launchctl', 'kickstart', '-k', domain + '/' + label])
            return
        if loaded:
            run(['launchctl', 'bootout', domain + '/' + label])
        # launchd may still be removing the old job after bootout returns.
        for attempt in range(20):
            result = subprocess.run(['launchctl', 'bootstrap', domain, str(path)], capture_output=True, text=True)
            if result.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('launchd could not start ' + label + ': ' + result.stderr)
    else:
        unit = Path.home() / '.config/systemd/user' / (label + '.service')
        unit.parent.mkdir(parents=True, exist_ok=True)
        # systemd syntax differs from shell quoting: JSON double quotes match this subset.
        command = ' '.join(json.dumps(str(a)) for a in argv)
        content = f'[Unit]\nDescription=Server tooling {name}\nAfter=network-online.target\n[Service]\nExecStart={command}\nWorkingDirectory={ROOT}\nRestart=always\nRestartSec=10\n[Install]\nWantedBy=default.target\n'
        unchanged = unit.exists() and unit.read_text() == content
        unit.write_text(content)
        run(['systemctl', '--user', 'daemon-reload'])
        run(['systemctl', '--user', 'enable', '--now', label + '.service'], stdout=subprocess.DEVNULL)
        if unchanged and name in ('prometheus', 'alertmanager', 'blackbox'):
            run(['systemctl', '--user', 'kill', '--kill-whom=main', '-s', 'HUP', label + '.service'])
        else:
            run(['systemctl', '--user', 'restart', label + '.service'])


def boot_script():
    """Stage the complete, inspectable privileged operation for the Mac owner."""
    source = SOURCE / 'enable_boot.py'
    shutil.copy2(source, ROOT / 'enable_boot.py')
    path = ROOT / 'enable-boot.sh'
    path.write_text('#!/bin/bash\nset -euo pipefail\nexec sudo ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(ROOT / 'enable_boot.py')) + ' ' + shlex.quote(str(ROOT)) + ' ' + shlex.quote(os.environ['USER']) + '\n')
    path.chmod(0o700)


def instrument(service_config):
    directory = Path(service_config['directory']).expanduser()
    wrapper = directory / service_config['wrapper']
    entry = directory / service_config['entry']
    if not wrapper.is_file() or not entry.is_file():
        raise RuntimeError('Missing service wrapper or entry: ' + service_config['name'])
    original = wrapper.read_text()
    if not re.search(r'^exec .+', original, re.M):
        raise RuntimeError('Unsupported service wrapper: ' + str(wrapper))
    hook = Path(str(wrapper) + '.monitoring.sh')
    hook_text = 'export NODE_OPTIONS="${NODE_OPTIONS:-} --require=' + str(ROOT / 'runtime.cjs') + '"\n'
    hook_text += 'export MONITORING_ENTRY=' + shlex.quote(str(entry)) + '\n'
    hook_text += 'export MONITORING_PORT=' + str(service_config['runtime_port']) + '\n'
    source_line = '[ ! -f ' + shlex.quote(str(hook)) + ' ] || source ' + shlex.quote(str(hook)) + '\n'
    if str(hook) not in original:
        backup = ROOT / 'backups/wrappers' / (service_config['name'] + '.sh')
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            backup.write_text(original)
            backup.chmod(0o600)
        wrapper.write_text(re.sub(r'(?m)^(exec .+)$', lambda match: source_line + match[1], original))
    changed = not hook.exists() or hook.read_text() != hook_text
    hook.write_text(hook_text)
    hook.chmod(0o600)
    return changed


def restart_app(item):
    if platform.system() == 'Linux':
        run(['systemctl', '--user', 'restart', item['unit'] + '.service'])
    elif item.get('scope') == 'system':
        run(['sudo', '-n', item['admin_helper'], 'restart', item['unit']])
    else:
        run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/' + item['unit']])


def ready(url, attempts=120):
    for _ in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError):
            time.sleep(1)
    raise RuntimeError('Not ready: ' + url)


def target(config):
    # Preflight every wrapper before changing any service.
    for item in config['services']:
        directory = Path(item['directory']).expanduser()
        if not (directory / item['entry']).is_file() or not (directory / item['wrapper']).is_file():
            raise RuntimeError('Invalid inventory for ' + item['name'])
    node = binary('node_exporter')
    service('node', [node, '--web.listen-address=127.0.0.1:19100'])
    runtime = ROOT / 'runtime.cjs'
    runtime_changed = not runtime.exists() or runtime.read_bytes() != (SOURCE / 'runtime.cjs').read_bytes()
    shutil.copy2(SOURCE / 'runtime.cjs', runtime)
    routes = {'/node': {'url': 'http://127.0.0.1:19100/metrics'}}
    for item in config['services']:
        name = item['name']
        wrapper = Path(item['directory']).expanduser() / item['wrapper']
        hook = Path(str(wrapper) + '.monitoring.sh')
        old_wrapper = wrapper.read_text()
        old_hook = hook.read_text() if hook.exists() else None
        try:
            if instrument(item) or runtime_changed:
                print('Restarting with runtime metrics:', name, flush=True)
                restart_app(item)
            ready(f'http://127.0.0.1:{item["runtime_port"]}/metrics')
        except Exception:
            wrapper.write_text(old_wrapper)
            if old_hook is None:
                hook.unlink(missing_ok=True)
            else:
                hook.write_text(old_hook)
            restart_app(item)
            raise
        routes['/runtime/' + name] = {'url': f'http://127.0.0.1:{item["runtime_port"]}/metrics'}
        if item.get('metrics_path'):
            route = {'url': f'http://127.0.0.1:{item["port"]}' + item['metrics_path']}
            if item.get('metrics_secret'):
                route['token_file'] = str(ROOT / 'secrets' / item['metrics_secret'])
                if not Path(route['token_file']).exists():
                    raise RuntimeError('Missing app metrics token: ' + item['metrics_secret'])
            routes['/app/' + name] = route
    write_json(ROOT / 'gateway.json', {'listen': config['ip'], 'allowed': config['allowed'], 'routes': routes})
    shutil.copy2(SOURCE / 'gateway.py', ROOT / 'gateway.py')
    service('gateway', [sys.executable, ROOT / 'gateway.py', ROOT / 'gateway.json'])


def monitor(config):
    prometheus, alertmanager, blackbox = [binary(x) for x in ('prometheus', 'alertmanager', 'blackbox_exporter')]
    watchdog = (ROOT / 'secrets' / ('HEALTHCHECKS_PING_URL_' + config['monitor'].upper())).exists()
    # Validate a complete candidate before replacing any active configuration.
    with tempfile.TemporaryDirectory(dir=ROOT, prefix='candidate-') as directory:
        candidate = Path(directory)
        shutil.copytree(ROOT / 'secrets', candidate / 'secrets')
        render(candidate, config['monitor'], config['target'], config['target_ip'], config['ip'], config['services'], watchdog)
        run([prometheus.parent / 'promtool', 'check', 'config', '--lint-fatal', candidate / 'prometheus.json'])
        run([alertmanager.parent / 'amtool', 'check-config', candidate / 'alertmanager.json'])
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        backup = ROOT / 'backups' / stamp
        backup.mkdir(parents=True)
        for path in candidate.rglob('*'):
            if not path.is_file() or 'secrets' in path.relative_to(candidate).parts:
                continue
            relative = path.relative_to(candidate)
            destination = ROOT / relative
            if destination.exists():
                saved = backup / relative
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(destination, saved)
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix(destination.suffix + '.new')
            temporary.write_text(path.read_text().replace(str(candidate), str(ROOT)))
            temporary.replace(destination)
    service('prometheus', [prometheus, '--config.file=' + str(ROOT / 'prometheus.json'), '--web.listen-address=127.0.0.1:19090',
                           '--storage.tsdb.path=' + str(ROOT / 'data/prometheus'), '--storage.tsdb.retention.time=30d', '--storage.tsdb.retention.size=5GB'])
    service('alertmanager', [alertmanager, '--config.file=' + str(ROOT / 'alertmanager.json'), '--web.listen-address=127.0.0.1:19093',
                             '--cluster.listen-address=', '--storage.path=' + str(ROOT / 'data/alertmanager')])
    service('blackbox', [blackbox, '--config.file=' + str(ROOT / 'blackbox.json'), '--web.listen-address=127.0.0.1:19115'])
    if platform.system() == 'Darwin':
        brew = shutil.which('brew')
        if not brew:
            raise RuntimeError('Homebrew required for Grafana on macOS')
        prefix = subprocess.check_output([brew, '--prefix', 'grafana'], text=True).strip()
        grafana = Path(prefix) / 'bin/grafana'
        if not grafana.exists():
            run([brew, 'install', 'grafana'])
        service('grafana', [grafana, 'server', '--homepath=' + prefix + '/share/grafana', '--config=' + str(ROOT / 'grafana.ini')])
        grafana_cli = [grafana, 'cli', '--homepath=' + prefix + '/share/grafana', '--config=' + str(ROOT / 'grafana.ini')]
    else:
        # Existing Linux hosts already use Docker. Only Grafana needs this backend.
        name = 'server-tooling-monitoring-grafana'
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(['docker', 'run', '-d', '--name', name, '--network=host', '--restart=unless-stopped', '--user', f'{os.getuid()}:{os.getgid()}',
             '-v', f'{ROOT}:{ROOT}', 'grafana/grafana:12.3.2', '--config=' + str(ROOT / 'grafana.ini')])
        grafana_cli = ['docker', 'exec', '-i', name, 'grafana', 'cli', '--homepath=/usr/share/grafana', '--config=' + str(ROOT / 'grafana.ini')]
    for port in [19090, 19093]:
        ready(f'http://127.0.0.1:{port}/-/ready')
    ready('http://' + config['ip'] + ':13000/api/health')
    password = (ROOT / 'secrets/GRAFANA_PASSWORD').read_text().strip()
    request = urllib.request.Request('http://' + config['ip'] + ':13000/api/user',
        headers={'Authorization': 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()})
    try:
        urllib.request.urlopen(request, timeout=10).close()
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
        error.close()
        # The initial-password setting only applies to new Grafana databases.
        run(grafana_cli + ['admin', 'reset-admin-password', '--password-from-stdin'],
            input=password + '\n', text=True, capture_output=True)
    print('Dashboard: http://' + config['ip'] + ':13000')
    print('External watchdog:', 'enabled' if watchdog else 'pending Healthchecks ping URL')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('role', choices=['target', 'monitor'])
    parser.add_argument('config')
    args = parser.parse_args()
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True)
    lock = (ROOT / 'install.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('Another monitoring installation is running on this host; retry when it finishes')
    for folder in ['data/prometheus', 'data/alertmanager', 'data/grafana', 'logs', 'secrets']:
        (ROOT / folder).mkdir(parents=True, exist_ok=True)
    with open(args.config) as stream:
        config = json.load(stream)
    if platform.system() == 'Linux':
        linger = subprocess.check_output(['loginctl', 'show-user', os.environ['USER'], '-p', 'Linger', '--value'], text=True).strip()
        if linger != 'yes':
            run(['sudo', '-n', 'loginctl', 'enable-linger', os.environ['USER']])
    globals()[args.role](config)
    if platform.system() == 'Darwin':
        boot_script()
        print('Boot startup requires: ' + str(ROOT / 'enable-boot.sh'))


if __name__ == '__main__':
    main()
