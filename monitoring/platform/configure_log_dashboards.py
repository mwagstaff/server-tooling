#!/usr/bin/env python3
"""Add the private log datasource to the existing public Grafana on Sky."""
import base64
import json
from pathlib import Path
import urllib.error
import urllib.request


def main():
    root = Path.home() / '.local/share/server-tooling-monitoring'
    config = json.loads((root / 'logging.json').read_text())
    password = (root / 'secrets/GRAFANA_PASSWORD').read_text().strip()
    headers = {'Authorization': 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode(),
               'Host': 'api.skynolimit.dev', 'X-Forwarded-Proto': 'https', 'Content-Type': 'application/json'}

    def request(path, body=None, method=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request('http://127.0.0.1:3001' + path, data, headers, method=method)
        return json.load(urllib.request.urlopen(req, timeout=15))

    source = {'name': 'Estate Logs', 'uid': 'monitoring-loki', 'type': 'loki', 'access': 'proxy',
              'url': config['url'], 'basicAuth': True, 'basicAuthUser': 'logs',
              'secureJsonData': {'basicAuthPassword': (root / 'secrets/LOKI_TOKEN').read_text().strip()},
              'jsonData': {'maxLines': 1000}}
    try:
        request('/api/datasources/uid/monitoring-loki')
        request('/api/datasources/uid/monitoring-loki', source, 'PUT')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        request('/api/datasources', source, 'POST')
    folder = 'kidsplorers-web-dashboards'
    try:
        request('/api/folders/' + folder)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        request('/api/folders', {'uid': folder, 'title': 'kidsplorers-web'}, 'POST')
    website = request('/api/dashboards/uid/kidsplorers-website')['dashboard']
    website['links'] = [link for link in website.get('links', []) if link.get('title') != 'Service logs'] + [
        {'title': 'Service logs', 'type': 'link', 'url': '/grafana/d/monitoring-logs?var-host=sky&var-service=kidsplorers-web',
         'includeVars': False, 'keepTime': True}]
    request('/api/dashboards/db', {'dashboard': website, 'folderUid': folder, 'overwrite': True}, 'POST')
    dashboard = {'uid': 'monitoring-logs', 'title': 'Service logs', 'schemaVersion': 39, 'version': 1,
                 'time': {'from': 'now-1h', 'to': 'now'}, 'refresh': '30s', 'tags': ['monitoring', 'logs'],
                 'templating': {'list': [
                     {'name': 'host', 'type': 'custom', 'query': 'mini,sky', 'current': {'text': 'sky', 'value': 'sky'}},
                     {'name': 'service', 'type': 'textbox', 'current': {'text': 'kidsplorers-web', 'value': 'kidsplorers-web'}},
                 ]},
                 'panels': [{'id': 1, 'title': 'Logs (collection-time entries are explicitly labelled)', 'type': 'logs',
                             'gridPos': {'x': 0, 'y': 0, 'w': 24, 'h': 22},
                             'datasource': {'type': 'loki', 'uid': 'monitoring-loki'},
                             'targets': [{'refId': 'A', 'expr': '{host=~"$host",service=~"$service"}'}],
                             'options': {'showTime': True, 'showLabels': True, 'wrapLogMessage': True, 'sortOrder': 'Descending'}}]}
    request('/api/dashboards/db', {'dashboard': dashboard, 'folderUid': folder, 'overwrite': True}, 'POST')
    health = request('/api/datasources/uid/monitoring-loki/health')
    print('Log datasource health:', health.get('status'))
    print('Website dashboard moved to kidsplorers-web; Service logs dashboard installed.')


if __name__ == '__main__':
    main()
