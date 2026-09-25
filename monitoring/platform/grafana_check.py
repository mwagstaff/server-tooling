"""Authenticated checks for the dashboards and their live data connection."""
import base64
import json
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
    if not {'monitoring-prometheus', 'monitoring-alertmanager'} <= sources:
        raise RuntimeError('Grafana monitoring data sources missing')
    data = read('/api/datasources/proxy/uid/monitoring-prometheus/api/v1/query?query=up')
    if data.get('status') != 'success' or not data['data']['result']:
        raise RuntimeError('Grafana cannot read monitoring metrics')
    return 'Grafana: 4 provisioned dashboards; live Prometheus data verified'
