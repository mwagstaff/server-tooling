#!/usr/bin/env python3
"""Private, allowlisted metrics proxy. Never accepts a caller-provided URL."""
import argparse
import http.client
import http.server
import ipaddress
import json
import logging
from pathlib import Path
import time
import urllib.error
import urllib.request
from history import start_history


LOGGER = logging.getLogger("metrics_gateway")
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SLOW_RESPONSE_SECONDS = 2


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.client_address[0] not in self.server.allowed:
            self.send_error(403)
            return
        if self.path == '/events':
            # Root-written, non-secret maintenance events; same peer allowlist as metrics.
            path = Path('/var/lib/server-tooling/events.prom')
            data = path.read_bytes() if path.exists() else b''
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        route = self.server.routes.get(self.path)
        if not route:
            self.send_error(404)
            return
        started = time.monotonic()
        stage = 'connect'
        details = {'route': self.path, 'upstream_status': None, 'response_bytes': 0}
        request = urllib.request.Request(route['url'])
        try:
            if route.get('token_file'):
                stage = 'credentials'
                with open(route['token_file']) as stream:
                    request.add_header('Authorization', 'Bearer ' + stream.read().strip())
            stage = 'connect'
            with self.server.opener.open(request, timeout=8) as response:
                details['upstream_status'] = response.status
                stage = 'read'
                data = response.read(MAX_RESPONSE_BYTES + 1)
                details['response_bytes'] = len(data)
                if len(data) > MAX_RESPONSE_BYTES:
                    self.log_result('response_too_large', started, stage, details)
                    self.send_error(502, 'Metrics response exceeds 8 MiB')
                    return
                expected = response.headers.get('Content-Length')
                if expected is not None and len(data) < int(expected):
                    raise http.client.IncompleteRead(data, int(expected) - len(data))
                content_type = response.headers.get('Content-Type', 'text/plain; version=0.0.4')
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException) as error:
            details['error_type'] = type(error).__name__
            # Exception messages, HTTP reason phrases and URLs may contain secrets.
            # Record only structural details, never upstream bodies or headers.
            cause = error.reason if isinstance(error, urllib.error.URLError) else error
            details['cause_type'] = type(cause).__name__
            if isinstance(cause, OSError):
                details['errno'] = cause.errno
            if isinstance(error, urllib.error.HTTPError):
                details['upstream_status'] = error.code
                error.close()
            if isinstance(error, http.client.IncompleteRead):
                details['response_bytes'] = len(error.partial)
                details['missing_bytes'] = error.expected
            self.log_result('upstream_failure', started, stage, details)
            try:
                self.send_error(502, 'Metrics endpoint unavailable')
            except OSError as write_error:
                self.log_result('client_disconnect', started, 'write_error',
                                dict(details, error_type=type(write_error).__name__))
            return
        try:
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except OSError as error:
            # The response has already started; do not attempt a second HTTP response.
            self.log_result('client_disconnect', started, 'write',
                            dict(details, error_type=type(error).__name__, errno=error.errno))
            return
        if time.monotonic() - started >= SLOW_RESPONSE_SECONDS:
            self.log_result('slow_response', started, 'complete', details)

    def log_result(self, event, started, stage, details):
        LOGGER.warning(json.dumps(dict(details, event=event, stage=stage,
                                       duration_ms=round((time.monotonic() - started) * 1000, 1)),
                                  sort_keys=True))

    def log_message(self, format, *args):
        # Successful requests and untrusted request paths stay out of access logs.
        pass


def main():
    logging.basicConfig(level=logging.WARNING, format="%(asctime)sZ %(levelname)s %(name)s %(message)s")
    logging.Formatter.converter = time.gmtime
    parser = argparse.ArgumentParser()
    parser.add_argument('config')
    args = parser.parse_args()
    with open(args.config) as stream:
        config = json.load(stream)
    address = ipaddress.ip_address(config['listen'])
    if address not in ipaddress.ip_network('100.64.0.0/10'):
        raise SystemExit('Gateway must bind a Tailscale IPv4 address')
    for route in config['routes'].values():
        if not route['url'].startswith('http://127.0.0.1:'):
            raise SystemExit('Gateway upstreams must use loopback')
    server = http.server.ThreadingHTTPServer((str(address), 19443), Handler)
    server.allowed = set(config['allowed']) | {'127.0.0.1'}
    server.routes = config['routes']
    server.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    if config.get('history'):
        start_history()
    server.serve_forever()


if __name__ == '__main__':
    main()
