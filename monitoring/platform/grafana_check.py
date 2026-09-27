"""Authenticated checks for the dashboards and their live data connection."""
import base64
import json
import time
import urllib.request


def check_grafana(url, password):
    headers = {'Authorization': 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()}
    def read(path):
        request = urllib.request.Request(url + path, headers=headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    expected = {'monitoring-' + name for name in ('fleet', 'host', 'service', 'monitor')}
    found = {item['uid'] for item in read('/api/search?type=dash-db')}
    if expected - found:
        raise RuntimeError('Grafana dashboards missing: ' + ', '.join(sorted(expected - found)))
    for uid in sorted(expected):
        dashboard = read('/api/dashboards/uid/' + uid)
        if not dashboard['meta'].get('provisioned') or not dashboard['dashboard'].get('panels'):
            raise RuntimeError('Grafana dashboard not provisioned: ' + uid)
    sources = {item['uid'] for item in read('/api/datasources')}
    if not {'monitoring-prometheus', 'monitoring-alertmanager', 'monitoring-history'} <= sources:
        raise RuntimeError('Grafana monitoring data sources missing')
    data = read('/api/datasources/proxy/uid/monitoring-prometheus/api/v1/query?query=up')
    if data.get('status') != 'success' or not data['data']['result']:
        raise RuntimeError('Grafana cannot read monitoring metrics')
    fleet = read('/api/dashboards/uid/monitoring-fleet')['dashboard']
    queries = []
    for title in ('Alert history', 'Host events'):
        panel = next((panel for panel in fleet['panels'] if panel['title'] == title), None)
        if not panel:
            raise RuntimeError('Grafana table missing: ' + title)
        queries.append(dict(panel['targets'][0], datasource=panel['datasource']))
    annotation = next((a for a in fleet.get('annotations', {}).get('list', []) if a['name'] == 'Host events'), None)
    if not annotation or not annotation.get('enable'):
        raise RuntimeError('Grafana host event annotations missing')
    queries.append(dict(annotation['target'], datasource=annotation['datasource']))
    end = int(time.time() * 1000)
    start = end - 86400000
    for query in queries:
        query['url'] = query['url'].replace('${__from}', str(start)).replace('${__to}', str(end)).replace('${host:percentencode}', '.*').replace('${service:percentencode}', '.*')
        request = urllib.request.Request(url + '/api/ds/query', json.dumps({'from': str(start), 'to': str(end), 'queries': [query]}).encode(),
                                         dict(headers, **{'Content-Type': 'application/json'}))
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)['results']['A']
        if result.get('error') or result.get('status', 200) != 200:
            raise RuntimeError('Grafana history/event query failed')
    return 'Grafana: 4 dashboards; live metrics, alert history, host events and annotation queries verified'
