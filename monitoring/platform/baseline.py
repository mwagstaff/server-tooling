#!/usr/bin/env python3
"""Report observed p95 latency and provisional thresholds; never changes rules."""
import argparse
from install import ssh

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', required=True)
args = parser.parse_args()
code = '''import json,urllib.parse,urllib.request
def query(expr):
 url='http://127.0.0.1:19090/api/v1/query?'+urllib.parse.urlencode({'query':expr})
 return json.load(urllib.request.urlopen(url))['data']['result']
days=query('sum by(service) (count_over_time(up{kind="runtime"}[14d])) * 15 / 86400')
latencies=query('quantile_over_time(0.95, monitoring:http_p95_seconds[14d])')
coverage={r['metric']['service']:float(r['value'][1]) for r in days}
for row in latencies:
 service=row['metric']['service']; value=float(row['value'][1]); days=coverage.get(service,0)
 print(json.dumps({'service':service,'observed_days':round(days,2),'busy_period_p95_seconds':value if value==value else None,'provisional_threshold_seconds':round(value*2,3) if value==value and days>=7 else None,'status':'review representative traffic before enabling' if days>=7 else 'collecting: at least 7 days needed'}))
'''
ssh(args.host, ['python3', '-c', code])
