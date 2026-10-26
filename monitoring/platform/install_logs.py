#!/usr/bin/env python3
"""Install the private Mini log store and collectors using reviewed pinned releases."""
import argparse
import base64
import configparser
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

from log_config import ALLOY_VERSION, LOKI_VERSION, alloy_config, loki_config

SOURCE = Path(__file__).resolve().parent


def binary(root, project, version):
    arch = 'darwin-arm64' if platform.system() == 'Darwin' else 'linux-amd64'
    name = project + '-' + arch
    destination = root / 'bin' / (name + '-' + version)
    if destination.exists():
        return destination
    base = f'https://github.com/grafana/{project}/releases/download/v{version}/'
    checksums = urllib.request.urlopen(base + 'SHA256SUMS', timeout=30).read().decode()
    expected = next(line.split()[0] for line in checksums.splitlines() if line.split()[-1].lstrip('*') == name + '.zip')
    data = urllib.request.urlopen(base + name + '.zip', timeout=120).read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError('Release checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        payload = archive.read(name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(payload)
    destination.chmod(0o700)
    return destination


def remote(config):
    import host as platform_host
    root = platform_host.ROOT
    os.umask(0o077)
    (root / 'logs').mkdir(parents=True, exist_ok=True)
    for file in ['log_gateway.py', 'log_canary.py']:
        shutil.copy2(SOURCE / file, root / file)
    (root / 'logging.json').write_text(json.dumps(config))
    if config['host'] == 'mini':
        loki = binary(root, 'loki', LOKI_VERSION)
        path = root / 'loki.json'
        path.write_text(json.dumps(loki_config(root)))
        subprocess.run([loki, '-config.file=' + str(path), '-verify-config=true'], check=True)
        platform_host.service('loki', ['/usr/bin/env', 'GOMEMLIMIT=512MiB', loki, '-config.file=' + str(path)])
        gateway = {'listen': config['central_ip'], 'allowed': config['allowed'],
                   'token_file': str(root / 'secrets/LOKI_TOKEN')}
        (root / 'log-gateway.json').write_text(json.dumps(gateway))
        platform_host.service('log-gateway', [sys.executable, root / 'log_gateway.py', root / 'log-gateway.json'])
    alloy = binary(root, 'alloy', ALLOY_VERSION)
    path = root / 'alloy.config'
    path.write_text(alloy_config(root, config['host'], config['services'], config['url'], platform.system() == 'Linux'))
    subprocess.run([alloy, 'validate', path], check=True)
    args = [str(alloy), 'run', '--stability.level=experimental', '--server.http.listen-addr=127.0.0.1:12345',
            '--storage.path=' + str(root / 'data/alloy'), str(path)]
    if platform.system() == 'Linux':
        # A system service with a non-root identity can read journald without
        # changing the operator's persistent group membership or login session.
        unit = ('[Unit]\nDescription=Private log collector\nAfter=network-online.target\n'
                '[Service]\nUser=' + os.environ['USER'] + '\nSupplementaryGroups=systemd-journal\n'
                'Environment=GOMEMLIMIT=256MiB\nExecStart=' + ' '.join(json.dumps(x) for x in args) +
                '\nRestart=always\nRestartSec=10\nMemoryMax=512M\nNoNewPrivileges=true\n'
                '[Install]\nWantedBy=multi-user.target\n')
        staged = root / 'server-tooling-alloy.service'
        staged.write_text(unit)
        subprocess.run(['sudo', '-n', 'install', '-m', '644', staged, '/etc/systemd/system/server-tooling-alloy.service'], check=True)
        subprocess.run(['sudo', '-n', 'systemctl', 'daemon-reload'], check=True)
        subprocess.run(['sudo', '-n', 'systemctl', 'enable', '--now', 'server-tooling-alloy'], check=True)
        subprocess.run(['sudo', '-n', 'systemctl', 'restart', 'server-tooling-alloy'], check=True)
    else:
        platform_host.service('alloy', ['/usr/bin/env', 'GOMEMLIMIT=256MiB'] + args)
    platform_host.service('log-canary', [sys.executable, root / 'log_canary.py'])
    gateway_path = root / 'gateway.json'
    gateway = json.loads(gateway_path.read_text())
    gateway['routes']['/logs-health'] = {'url': 'http://127.0.0.1:13102/metrics'}
    gateway['routes']['/alloy'] = {'url': 'http://127.0.0.1:12345/metrics'}
    gateway_path.write_text(json.dumps(gateway))
    platform_host.service('gateway', [sys.executable, root / 'gateway.py', gateway_path])
    if platform.system() == 'Darwin':
        platform_host.boot_script()
    print('Log services installed on ' + config['host'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--remote', type=Path)
    args = parser.parse_args()
    if args.remote:
        remote(json.loads(args.remote.read_text()))
        return
    from install import inspect, ssh, run
    hosts = {name: inspect(name) for name in ['mini', 'sky']}
    remote_root = '.local/share/server-tooling-monitoring'
    token = subprocess.run(['ssh', 'mini', 'cat ~/' + remote_root + '/secrets/LOKI_TOKEN'], capture_output=True, text=True)
    token = token.stdout.strip() if token.returncode == 0 else secrets.token_urlsafe(48)
    services = json.loads((SOURCE.parents[1] / 'aiops/config/services.json').read_text())
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        secret = work / 'LOKI_TOKEN'
        secret.write_text(token)
        secret.chmod(0o600)
        for name, info in hosts.items():
            root = info['home'] + '/' + remote_root
            stage = root + '/source/logging'
            ssh(name, ['mkdir', '-p', stage])
            for file in ['install_logs.py', 'log_config.py', 'log_gateway.py', 'log_canary.py',
                         'host.py', 'enable_boot.py', 'config.py', 'application_rules.py', 'grafana_check.py', 'history.py']:
                run(['scp', '-q', SOURCE / file, name + ':' + stage + '/' + file])
            run(['scp', '-q', secret, name + ':' + root + '/secrets/LOKI_TOKEN'])
            ssh(name, ['chmod', '600', root + '/secrets/LOKI_TOKEN'])
            config = {'host': name, 'central_ip': hosts['mini']['ip'],
                      'allowed': [x['ip'] for x in hosts.values()] + ['127.0.0.1'],
                      'url': 'http://' + hosts['mini']['ip'] + ':13101', 'services': services}
            path = work / 'deploy.json'
            path.write_text(json.dumps(config))
            run(['scp', '-q', path, name + ':' + stage + '/deploy.json'])
            ssh(name, ['python3', stage + '/install_logs.py', '--remote', stage + '/deploy.json'])


if __name__ == '__main__':
    main()
