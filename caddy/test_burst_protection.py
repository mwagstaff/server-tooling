"""Exercise the actual Kidsplorers proxy block against a disposable origin.

Run with python3 -m unittest discover -s caddy -p 'test_*.py' -v.
Requires Caddy; all listeners are loopback-only and production is untouched.
"""
import concurrent.futures
import http.client
import http.server
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest


@unittest.skipUnless(shutil.which('caddy'), 'Caddy executable required')
class BurstProtectionTest(unittest.TestCase):
    def test_discovery_headroom_and_recovery(self):
        release = threading.Event()
        entered = threading.Condition()
        active = 0

        class Origin(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                nonlocal active
                if 'hold=1' in self.path:
                    with entered:
                        active += 1
                        entered.notify_all()
                    release.wait(20)
                self.send_response(200)
                self.send_header('Content-Length', '2')
                self.end_headers()
                self.wfile.write(b'OK')

            def log_message(self, *args):
                pass

        origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0))
            proxy_port = reserved.getsockname()[1]

        def request(path):
            conn = http.client.HTTPConnection('127.0.0.1', proxy_port, timeout=25)
            try:
                conn.request('GET', path, headers={'Host': 'kidsplorers.com'})
                response = conn.getresponse()
                response.read()
                return response.status
            finally:
                conn.close()

        source = Path(__file__).with_name('setup-caddy-cloudflare-tunnel.zsh').read_text()
        start = source.index('  handle @kidsplorers_web {')
        block = source[start:source.index('\n  # Sky No Limit', start)]
        block = block.replace('127.0.0.1:3200', f'127.0.0.1:{origin.server_port}')
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'Caddyfile'
            config.write_text('''{
 admin off
 auto_https off
 persist_config off
}\n''' +
                f'http://:{proxy_port} {{\n  bind 127.0.0.1\n' +
                '  @kidsplorers_web host kidsplorers.com\n' + block + '\n}\n')
            with (Path(tmp) / 'caddy.log').open('w+') as log:
                caddy = subprocess.Popen(['caddy', 'run', '--config', str(config)],
                                         stdout=log, stderr=log)
                pool = concurrent.futures.ThreadPoolExecutor(max_workers=32)
                try:
                    for _ in range(100):
                        try:
                            if request('/healthcheck') == 200:
                                break
                        except OSError:
                            time.sleep(0.05)
                    else:
                        log.seek(0)
                        self.fail(log.read())
                    pending = []
                    for i in range(32):
                        if i == 12:
                            self.assertEqual(request('/places/map'), 503)
                            self.assertEqual(request('/places?rainyDay=true'), 503)
                            self.assertEqual(request('/healthcheck'), 200)
                        path = '/places/map?hold=1' if i < 12 else '/other?hold=1'
                        pending.append(pool.submit(request, path))
                        with entered:
                            self.assertTrue(entered.wait_for(lambda: active == i + 1, timeout=3),
                                            f'request {i + 1}: active={active}, '
                                            f'status={pending[-1].result() if pending[-1].done() else "pending"}')
                    self.assertEqual(request('/other'), 503)
                    release.set()
                    self.assertTrue(all(f.result() == 200 for f in pending))
                    self.assertEqual(request('/places/map'), 200)
                    self.assertEqual(request('/healthcheck'), 200)
                finally:
                    release.set()
                    pool.shutdown(wait=True)
                    caddy.terminate()
                    caddy.wait(timeout=5)
                    origin.shutdown()
                    origin.server_close()
