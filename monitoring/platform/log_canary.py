#!/usr/bin/env python3
"""Exercise file collection through Loki and expose freshness to peer monitoring."""
import base64
import http.server
import json
import shutil
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path


def main():
    root = Path.home() / '.local/share/server-tooling-monitoring'
    config = json.loads((root / 'logging.json').read_text())
    token = (root / 'secrets/LOKI_TOKEN').read_text().strip()
    auth = 'Basic ' + base64.b64encode(('logs:' + token).encode()).decode()
    logfile = root / 'logs/log-canary.jsonl'

    def write():
        while True:
            with logfile.open('a') as out:
                out.write(json.dumps({'ts': time.time(), 'event': 'log_pipeline_canary'}) + '\n')
            # Small rotating input; Alloy handles truncation. Keep several hours.
            if logfile.stat().st_size > 1024 * 1024:
                logfile.write_text('')
            time.sleep(60)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/metrics':
                self.send_error(404)
                return
            stamp = 0
            try:
                query = '{host=' + json.dumps(config['host']) + ',service="log-canary"}'
                params = urllib.parse.urlencode({'query': query, 'limit': 1, 'direction': 'backward', 'since': '1h'})
                request = urllib.request.Request(config['url'] + '/loki/api/v1/query_range?' + params,
                                                 headers={'Authorization': auth})
                with urllib.request.urlopen(request, timeout=5) as response:
                    streams = json.load(response)['data']['result']
                stamp = max((float(value[0]) / 1e9 for stream in streams for value in stream['values']), default=0)
            except Exception:
                pass
            body = (f'logging_canary_timestamp_seconds {stamp}\n'
                    f'logging_disk_free_bytes {shutil.disk_usage(root).free}\n').encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    threading.Thread(target=write, daemon=True).start()
    http.server.ThreadingHTTPServer(('127.0.0.1', 13102), Handler).serve_forever()


if __name__ == '__main__':
    main()
