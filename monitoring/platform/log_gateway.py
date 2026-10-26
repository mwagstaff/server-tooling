#!/usr/bin/env python3
"""Private authenticated Loki gateway; no delete, admin or caller-selected upstreams."""
import base64
import hmac
import http.client
import http.server
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.proxy()

    def do_POST(self):
        self.proxy()

    def proxy(self):
        self.connection.settimeout(20)
        if self.client_address[0] not in self.server.allowed or not hmac.compare_digest(
                self.headers.get('Authorization', ''), self.server.authorization):
            self.send_error(403)
            return
        path = urlsplit(self.path).path
        reads = {'/ready', '/loki/api/v1/query', '/loki/api/v1/query_range',
                 '/loki/api/v1/labels', '/loki/api/v1/series', '/loki/api/v1/index/stats'}
        label = path.startswith('/loki/api/v1/label/') and path.endswith('/values')
        if not ((self.command == 'GET' and (path in reads or label)) or
                (self.command == 'POST' and path == '/loki/api/v1/push')):
            self.send_error(404)
            return
        upstream = http.client.HTTPConnection('127.0.0.1', 13100, timeout=15)
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 4 * 1024 * 1024 or self.headers.get('Transfer-Encoding'):
                self.send_error(413)
                return
            data = self.rfile.read(length) if length else None
            upstream.request(self.command, self.path, body=data, headers={
                'Content-Type': self.headers.get('Content-Type', 'application/json')})
            response = upstream.getresponse()
            body = response.read(8 * 1024 * 1024 + 1)
            if len(body) > 8 * 1024 * 1024:
                self.send_error(502)
                return
            self.send_response(response.status)
            self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (OSError, ValueError, http.client.HTTPException):
            self.send_error(502)
        finally:
            upstream.close()

    def log_message(self, *args):
        pass  # Queries and headers may contain sensitive values.


def main():
    config = json.loads(Path(sys.argv[1]).read_text())
    server = http.server.ThreadingHTTPServer((config['listen'], 13101), Handler)
    server.allowed = set(config['allowed'])
    token = Path(config['token_file']).read_text().strip()
    server.authorization = 'Basic ' + base64.b64encode(('logs:' + token).encode()).decode()
    server.serve_forever()


if __name__ == '__main__':
    main()
