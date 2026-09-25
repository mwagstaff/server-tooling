#!/usr/bin/env python3
"""Deploy independent monitoring using SSH and the existing Bitwarden vault."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import uuid

SOURCE = Path(__file__).resolve().parent
REMOTE_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
BW_FOLDER = '7a5cbc24-a5c4-4d07-bbf3-b3f600e24660'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def ssh(host, args, **kwargs):
    return run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', host,
                'env PATH=' + shlex.quote(REMOTE_PATH) + ' ' + shlex.join([str(x) for x in args])], **kwargs)


def inspect(host):
    code = '''import json,os,shutil,subprocess
t=shutil.which('tailscale')
if not t: raise SystemExit('Tailscale is not installed')
p=subprocess.run([t,'ip','-4'],capture_output=True,text=True,check=True)
ip=p.stdout.strip().splitlines()[0]
print(json.dumps({'home':os.path.expanduser('~'),'ip':ip}))'''
    return json.loads(ssh(host, ['python3', '-c', code], capture_output=True, text=True).stdout)


def vault_items():
    env = os.environ.copy()
    cache = Path.home() / '.cache/server-tooling/bitwarden-session'
    if not env.get('BW_SESSION') and cache.exists():
        env['BW_SESSION'] = cache.read_text().strip()
    sync = subprocess.run(['bw', '--nointeraction', 'sync'], env=env, capture_output=True, text=True)
    if sync.returncode:
        raise RuntimeError('Unlock Bitwarden first with: export BW_SESSION="$(bw unlock --raw)"')
    result = run(['bw', '--nointeraction', 'list', 'items', '--folderid', os.environ.get('BW_FOLDER_ID', BW_FOLDER)], env=env, capture_output=True, text=True)
    items = json.loads(result.stdout)
    # The existing Grafana installer stores this login outside the deploy folder.
    grafana = run(['bw', '--nointeraction', 'list', 'items', '--search', 'GRAFANA'], env=env, capture_output=True, text=True)
    known = {item['id'] for item in items}
    items.extend(item for item in json.loads(grafana.stdout) if item.get('name') in ('GRAFANA_LOGIN', 'GRAFANA_PASSWORD') and item['id'] not in known)
    return items


def get_secret(items, name, app='monitoring', optional=False):
    matches = []
    for item in items:
        if item.get('name') != name:
            continue
        fields = item.get('fields') or []
        apps = next((field.get('value', '') or '' for field in fields if field.get('name', '').lower() == 'apps'), '')
        if app and app not in re.split(r'[,;\s]+', apps.lower()):
            continue
        value = next((field.get('value') for field in fields if field.get('name', '').lower() != 'apps' and field.get('value')), None)
        value = value or (item.get('login') or {}).get('password')
        if name in ('GRAFANA_LOGIN', 'GRAFANA_PASSWORD'):
            value = (item.get('login') or {}).get('password')
        if value:
            matches.append(value)
    if len(matches) > 1:
        raise RuntimeError('Duplicate Bitwarden entry: ' + name)
    if not matches and not optional:
        raise RuntimeError(f'Bitwarden entry {name} missing or empty; set Apps to {app}')
    return matches[0] if matches else None


def validate_services(services):
    names, ports = set(), set()
    if not services:
        raise RuntimeError('Target inventory is empty')
    for item in services:
        name, port = item['name'], item['runtime_port']
        if not re.fullmatch(r'[a-z][a-z0-9-]*', name) or name in names:
            raise RuntimeError('Invalid or duplicate service name: ' + name)
        if not isinstance(port, int) or not 19200 <= port < 19400 or port in ports:
            raise RuntimeError('Use unique runtime ports in 19200–19399')
        if Path(item['entry']).is_absolute() or '..' in Path(item['entry']).parts:
            raise RuntimeError('Service entry must be relative to its directory')
        if '/' in item['wrapper'] or not item['wrapper'].endswith('.sh'):
            raise RuntimeError('Service wrapper must be a shell filename')
        if item.get('latency_p95_seconds') is not None and not 0 < item['latency_p95_seconds'] <= 60:
            raise RuntimeError('Latency threshold must be between 0 and 60 seconds')
        names.add(name)
        ports.add(port)


def stage(host, info, config, secret_values, work):
    remote = info['home'] + '/.local/share/server-tooling-monitoring'
    source = remote + '/source/' + uuid.uuid4().hex
    ssh(host, ['mkdir', '-p', source, remote + '/secrets'])
    ssh(host, ['chmod', '700', remote, remote + '/secrets'])
    for name in ['host.py', 'config.py', 'gateway.py', 'runtime.cjs', 'enable_boot.py']:
        run(['scp', '-q', SOURCE / name, host + ':' + source + '/' + name])
    config_path = work / (host + '-deploy.json')
    config_path.write_text(json.dumps(config))
    run(['scp', '-q', config_path, host + ':' + source + '/deploy.json'])
    for name, value in secret_values.items():
        if value is None:
            continue
        path = work / name
        path.write_text(value)
        path.chmod(0o600)
        run(['scp', '-q', path, host + ':' + remote + '/secrets/' + name])
        ssh(host, ['chmod', '600', remote + '/secrets/' + name])
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--monitor', required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--inventory', type=Path, default=SOURCE / 'inventory.json')
    parser.add_argument('--skip-target', action='store_true', help='Update dashboards/rules/secrets only')
    parser.add_argument('--keep-secrets', action='store_true', help='Use credentials already installed on hosts')
    args = parser.parse_args()
    for name in [args.monitor, args.target]:
        if not re.fullmatch(r'[a-z][a-z0-9-]*', name):
            parser.error('Use a simple SSH host alias: ' + name)
    if args.monitor == args.target:
        parser.error('Independent monitoring requires different hosts')
    inventory = json.loads(args.inventory.read_text())
    if args.target not in inventory['hosts']:
        parser.error('Add the target host to ' + str(args.inventory))
    services = inventory['hosts'][args.target]['services']
    validate_services(services)
    monitor_info, target_info = inspect(args.monitor), inspect(args.target)
    monitor_secrets, target_secrets = {}, {}
    if not args.keep_secrets:
        items = vault_items()
        for name in ['PUSHOVER_USER_KEY', 'PUSHOVER_API_KEY_MONITORING']:
            monitor_secrets[name] = get_secret(items, name)
        watchdog = 'HEALTHCHECKS_PING_URL_' + args.monitor.upper()
        monitor_secrets[watchdog] = get_secret(items, watchdog, optional=True)
        monitor_secrets['GRAFANA_PASSWORD'] = get_secret(items, 'GRAFANA_PASSWORD', app=None, optional=True) or get_secret(items, 'GRAFANA_LOGIN', app=None, optional=True)
        if not monitor_secrets['GRAFANA_PASSWORD']:
            raise RuntimeError('Create GRAFANA_PASSWORD in Bitwarden with a login password for the dashboard')
        for item in services:
            if item.get('metrics_secret'):
                # Existing app-owned token; never associate monitoring notification keys with apps.
                target_secrets[item['metrics_secret']] = get_secret(items, item['metrics_secret'], app=None)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='monitoring-deploy-') as directory:
        work = Path(directory)
        if not args.skip_target:
            config = {'services': services, 'ip': target_info['ip'], 'allowed': [monitor_info['ip']]}
            source = stage(args.target, target_info, config, target_secrets, work)
            ssh(args.target, ['python3', source + '/host.py', 'target', source + '/deploy.json'])
        config = {'monitor': args.monitor, 'target': args.target, 'ip': monitor_info['ip'], 'target_ip': target_info['ip'], 'services': services}
        source = stage(args.monitor, monitor_info, config, monitor_secrets, work)
        ssh(args.monitor, ['python3', source + '/host.py', 'monitor', source + '/deploy.json'])
    print('Installed. Check the dashboards and expected target count before retiring legacy alerts.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        # Never include captured Bitwarden output or secret values.
        print(str(error), file=sys.stderr)
        sys.exit(1)
