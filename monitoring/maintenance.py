#!/usr/bin/env python3
"""Open bounded AIOps/Alertmanager maintenance; no persistent pause or cleanup trap."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
import urllib.request


def request(url, token, payload):
    req = urllib.request.Request(url + '/api/maintenance', data=json.dumps(payload).encode(),
                                 headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=45) as response:
        return json.load(response)


def service_names(inventory, host, units):
    rows = inventory['hosts'].get(host, {}).get('services', [])
    names = [row['name'] for row in rows if row['unit'] in units]
    if 'com.aiops.api' in units:
        names.append('aiops')
    missing = set(units) - {row['unit'] for row in rows} - {'com.aiops.api'}
    if missing:
        raise ValueError('Unregistered deployment units: ' + ', '.join(sorted(missing)))
    if not names:
        raise ValueError('No registered services selected')
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', choices=['mini', 'sky'])
    parser.add_argument('--unit', action='append', default=[])
    parser.add_argument('--host-wide', action='store_true')
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--reason', default='Planned deployment')
    parser.add_argument('--state-dir', type=Path, help='Local AIOps state for a host-side reboot hook')
    args = parser.parse_args()
    if not 30 <= args.seconds <= 1800:
        parser.error('Window must be 30–1800 seconds')
    config = json.loads((args.state_dir / 'config.json').read_text()) if args.state_dir else None
    host = config['host'] if config else args.host
    if host not in ('mini', 'sky'):
        parser.error('Specify an enrolled Mini/Sky host')
    if args.host_wide and args.unit:
        parser.error('Choose host-wide maintenance or service units, not both')
    services = [] if args.host_wide else service_names(
        json.loads(Path(__file__).with_name('platform').joinpath('inventory.json').read_text()), host, args.unit)
    payload = dict(host=host, services=services, seconds=args.seconds, reason=args.reason)
    owner = 'mini' if host == 'sky' else 'sky'
    if config:
        values = dict(token.split('=', 1) for token in shlex.split((args.state_dir / 'secrets.env').read_text(), comments=True) if '=' in token)
        result = request(config['peers'][owner], values['AIOPS_PEER_TOKEN'], payload)
    else:
        # Read the credential on its owning host; never put it in command arguments or output.
        code = '''import json,pathlib,urllib.request
p=pathlib.Path.home()/'.local/share/aiops/webhook-token'
r=urllib.request.Request('http://127.0.0.1:19444/api/maintenance',data=PAYLOAD.encode(),headers={'Authorization':'Bearer '+p.read_text().strip(),'Content-Type':'application/json'})
try:
 with urllib.request.urlopen(r,timeout=45) as response: print(response.read().decode())
except Exception:
 raise SystemExit('Maintenance request failed on owning responder')
'''.replace('PAYLOAD', repr(json.dumps(payload)))
        response = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', owner, 'python3 -'],
                                  input=code, capture_output=True, text=True, timeout=60, check=True)
        result = json.loads(response.stdout)
    print('Maintenance active for ' + host + '/' + (', '.join(services) or 'all services') +
          ': ' + str(args.seconds) + ' seconds; automatically expires.')
    return result


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Avoid response bodies, credentials and remote command dumps in deploy logs.
        print('Could not establish maintenance. Monitoring remains enabled; planned downtime may alert.', file=sys.stderr)
        sys.exit(1)
