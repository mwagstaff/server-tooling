#!/usr/bin/env python3
"""Inspect real scrape/rule health, optionally send a self-resolving notification."""
import argparse
import json
import subprocess
import sys
from install import ssh

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', required=True)
parser.add_argument('--test-alert', action='store_true')
args = parser.parse_args()
code = '''import datetime,json,urllib.request,urllib.parse
def read(path):
 return json.load(urllib.request.urlopen('http://127.0.0.1:19090'+path))['data']
targets=read('/api/v1/targets')['activeTargets']
for t in targets:
 print(t['labels'].get('job'),t['health'],t.get('lastError',''))
bad=[t for t in targets if t['health']!='up']
groups=read('/api/v1/rules')['groups']
rules=[r for g in groups for r in g['rules']]
failed=[r for r in rules if r['health']!='ok']
probes=read('/api/v1/query?'+urllib.parse.urlencode({'query':'probe_success == 0'}))['result']
for probe in probes: print('PUBLIC PROBE FAILED:',probe['metric'].get('service'))
print('Targets:',len(targets),'unhealthy:',len(bad),'rules:',len(rules),'unhealthy:',len(failed))
for r in failed: print(r['name'],r.get('lastError'))
if TEST:
 now=datetime.datetime.now(datetime.timezone.utc)
 alert={'labels':{'alertname':'MonitoringDeliveryTest','severity':'warning','host':'HOST','service':'monitoring'},'annotations':{'summary':'Monitoring Pushover delivery test; resolves automatically'},'startsAt':now.isoformat(),'endsAt':(now+datetime.timedelta(minutes=2)).isoformat()}
 request=urllib.request.Request('http://127.0.0.1:19093/api/v2/alerts',json.dumps([alert]).encode(),{'Content-Type':'application/json'})
 urllib.request.urlopen(request).close()
 print('Test alert submitted; check Pushover for firing and recovery messages.')
if bad or failed or probes: raise SystemExit(1)
'''.replace('TEST', repr(args.test_alert)).replace('HOST', args.host)
try:
    ssh(args.host, ['python3', '-c', code])
except subprocess.CalledProcessError:
    sys.exit(1)
