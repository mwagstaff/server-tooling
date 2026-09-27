"""Read-only alert history reconstructed from retained Prometheus samples.

Served on loopback by the existing gateway process; no new event database.
"""
import datetime
import http.server
import json
import re
import threading
import time
import urllib.parse
import urllib.request

RETENTION = 30 * 86400


def read_prometheus(path, params=None):
    url = 'http://127.0.0.1:19090' + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=25) as response:
        raw = response.read(64 * 1024 * 1024 + 1)
    if len(raw) > 64 * 1024 * 1024:
        raise RuntimeError('Alert history exceeds the response budget; narrow retention')
    data = json.loads(raw)
    if data.get('status') != 'success':
        raise RuntimeError('Prometheus history query failed')
    return data['data']


def identity(labels):
    return tuple(sorted((k, v) for k, v in labels.items() if k not in ('__name__', 'alertstate')))


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def episodes(series, groups, now):
    rules = {}
    active = {}
    for group in groups:
        for rule in group['rules']:
            if rule['type'] != 'alerting':
                continue
            rules[rule['name']] = (rule, group)
            for alert in rule.get('alerts', []):
                if alert['state'] == 'firing':
                    active[identity(alert['labels'])] = (alert, rule['duration'])
    rows = []
    for item in series:
        labels = item['metric']
        rule, group = rules.get(labels['alertname'], ({}, {}))
        interval = group.get('interval', 15)
        periods = []
        for t, value in item['values']:
            if value != '1':
                continue
            if not periods or t - periods[-1][-1] > interval * 1.5:
                periods.append([])
            periods[-1].append(t)
        current = active.get(identity(labels))
        for period in periods:
            first, last = period[0], period[-1]
            summary = rule.get('annotations', {}).get('summary', labels['alertname'])
            summary = re.sub(r'{{\s*\$labels\.(\w+)\s*}}', lambda m: labels.get(m[1], ''), summary)
            fresh = rule.get('health') == 'ok' and now - timestamp(group['lastEvaluation']) < max(60, interval * 3)
            status = 'Resolved' if fresh else 'Unknown'
            if current:
                alert, duration = current
                started = timestamp(alert['activeAt']) + duration
                if first - interval <= started <= last + interval or (started < first and last >= now - interval * 2):
                    status = 'Firing' if fresh else 'Unknown'
                    first = started
                    summary = alert.get('annotations', {}).get('summary', summary)
            rows.append({'alert': labels['alertname'], 'host': labels.get('host', ''),
                         'service': labels.get('service', ''), 'severity': labels.get('severity', ''),
                         'summary': summary, 'fired_at': int(first * 1000),
                         'last_firing': int(last * 1000), 'status': status})
    return sorted(rows, key=lambda row: row['fired_at'], reverse=True)


class History:
    def __init__(self):
        self.lock = threading.Lock()
        self.updated = 0
        self.rows = []

    def query(self, start, end, host='.*', service='.*'):
        now = time.time()
        if not (0 <= start <= end and end - start <= RETENTION * 1000):
            raise ValueError('Select a time range of at most 30 days')
        # Match literal dropdown values, not arbitrary user-supplied regexes.
        def matches(value, selected):
            return selected in ('.*', '$__all', 'All') or value == selected
        with self.lock:
            if now - self.updated >= 30:
                data = read_prometheus('/api/v1/query', {'query': 'ALERTS{alertstate="firing",alertname!="MonitoringWatchdog"}[30d]'})
                groups = read_prometheus('/api/v1/rules', {'type': 'alert'})['groups']
                self.rows = episodes(data['result'], groups, now)
                self.updated = now
            return [row for row in self.rows if row['fired_at'] <= end and row['last_firing'] >= start
                    and matches(row['host'], host) and matches(row['service'], service)]


class HistoryHandler(http.server.BaseHTTPRequestHandler):
    history = History()

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path != '/history':
            self.send_error(404)
            return
        try:
            params = urllib.parse.parse_qs(url.query)
            get = lambda key, default: params.get(key, [default])[0]
            data = self.history.query(int(get('from', '0')), int(get('to', str(int(time.time() * 1000)))),
                                      get('host', '.*'), get('service', '.*'))
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (ValueError, KeyError):
            self.send_error(400, 'Invalid history range or filters')
        except (OSError, RuntimeError):
            # Never serve cached resolved status when Prometheus is unavailable.
            self.send_error(503, 'Alert history temporarily unavailable')

    def log_message(self, format, *args):
        pass


def start_history():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 19116), HistoryHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
