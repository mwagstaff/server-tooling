#!/usr/bin/env python3
"""Private, allowlisted metrics proxy. Never accepts a caller-provided URL."""
import argparse
import http.server
import ipaddress
import json
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.client_address[0] not in self.server.allowed:
            self.send_error(403)
            return
        route = self.server.routes.get(self.path)
        if not route:
            self.send_error(404)
            return
        request = urllib.request.Request(route['url'])
        try:
            if route.get('token_file'):
                with open(route['token_file']) as stream:
                    request.add_header('Authorization', 'Bearer ' + stream.read().strip())
            with self.server.opener.open(request, timeout=8) as response:
                data = response.read(8 * 1024 * 1024 + 1)
                if len(data) > 8 * 1024 * 1024:
                    raise ValueError('Metrics response exceeds 8 MiB')
                content_type = response.headers.get('Content-Type', 'text/plain; version=0.0.4')
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (OSError, ValueError, urllib.error.URLError):
            self.send_error(502, 'Metrics endpoint unavailable')

    def log_message(self, format, *args):
        # No URLs or credentials in request logs.
        pass


def main():
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
    server.serve_forever()


if __name__ == '__main__':
    main()
