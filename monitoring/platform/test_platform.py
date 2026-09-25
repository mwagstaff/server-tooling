import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).parent))
from config import render
from gateway import Handler, NoRedirect
from install import get_secret
import host


def free_port():
    with socket.socket() as stream:
        stream.bind(('127.0.0.1', 0))
        return stream.getsockname()[1]


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        error.close()
        raise


class PlatformTests(unittest.TestCase):
    def test_instrumentation_is_repeatable_and_preserves_node_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            previous_root = host.ROOT
            self.addCleanup(setattr, host, 'ROOT', previous_root)
            host.ROOT = root
            (root / 'runtime.cjs').write_bytes(Path(__file__).with_name('runtime.cjs').read_bytes())
            entry = root / 'app.cjs'
            entry.write_text('console.log(process.env.NODE_OPTIONS)')
            wrapper = root / 'start.sh'
            wrapper.write_text('#!/bin/bash\nexport NODE_OPTIONS="--max-old-space-size=192"\nexec node "' + str(entry) + '"\n')
            config = dict(directory=str(root), wrapper='start.sh', entry='app.cjs', name='fixture', runtime_port=free_port())
            self.assertTrue(host.instrument(config))
            self.assertFalse(host.instrument(config))
            output = subprocess.check_output(['bash', str(wrapper)], text=True, timeout=5)
            self.assertIn('--max-old-space-size=192', output)
            self.assertEqual(output.count('--require='), 1)

    def test_credentials_are_scoped_and_duplicates_rejected(self):
        def item(app):
            return {'name': 'PUSHOVER_USER_KEY', 'fields': [{'name': 'Apps', 'value': app}], 'login': {'password': 'test-only'}}
        with self.assertRaises(RuntimeError):
            get_secret([item('top-scores')], 'PUSHOVER_USER_KEY')
        self.assertEqual(get_secret([item('monitoring')], 'PUSHOVER_USER_KEY'), 'test-only')
        with self.assertRaises(RuntimeError):
            get_secret([item('monitoring'), item('monitoring')], 'PUSHOVER_USER_KEY')

    def test_reverse_roles_and_missing_watchdog(self):
        for monitor, target in [('mini', 'sky'), ('sky', 'mini')]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                render(root, monitor, target, '100.64.0.2', '100.64.0.1', [{'name': 'app', 'public_url': 'https://example.com'}])
                config = json.loads((root / 'prometheus.json').read_text())
                self.assertEqual(config['global']['external_labels']['monitor'], monitor)
                self.assertEqual(config['scrape_configs'][0]['static_configs'][0]['labels']['host'], target)
                am = json.loads((root / 'alertmanager.json').read_text())
                self.assertEqual(am['route']['routes'][0]['receiver'], 'silent')
                render(root, monitor, target, '100.64.0.2', '100.64.0.1', [], watchdog=True)
                am = json.loads((root / 'alertmanager.json').read_text())
                receiver = next(x for x in am['receivers'] if x['name'] == 'watchdog')
                self.assertFalse(receiver['webhook_configs'][0]['send_resolved'])
                self.assertTrue(receiver['webhook_configs'][0]['url_file'].endswith(monitor.upper()))

    def test_gateway_rejects_unlisted_clients_and_urls(self):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.routes = {}
        server.allowed = set()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f'http://127.0.0.1:{server.server_port}'
            with self.assertRaises(urllib.error.HTTPError) as result:
                get(url + '/node')
            self.assertEqual(result.exception.code, 403)
            server.allowed.add('127.0.0.1')
            with self.assertRaises(urllib.error.HTTPError) as result:
                get(url + '/?target=http://169.254.169.254')
            self.assertEqual(result.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()

    def test_runtime_metrics_match_real_http_and_stable_start_time(self):
        with tempfile.TemporaryDirectory() as directory:
            entry = Path(directory) / 'server.cjs'
            app_port, metrics_port = free_port(), free_port()
            entry.write_text("const h=require('http'); h.createServer((q,s)=>{s.statusCode=q.url==='/error'?503:200;s.end('ok')}).listen(Number(process.env.PORT),'127.0.0.1');")
            env = dict(os.environ, PORT=str(app_port), MONITORING_ENTRY=str(entry), MONITORING_PORT=str(metrics_port))
            process = subprocess.Popen(['node', '--require', str(Path(__file__).with_name('runtime.cjs')), str(entry)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                metrics_url = f'http://127.0.0.1:{metrics_port}/metrics'
                for _ in range(50):
                    try:
                        before = get(metrics_url)
                        break
                    except OSError:
                        time.sleep(.05)
                else:
                    self.fail('Node metrics failed to start')
                get(f'http://127.0.0.1:{app_port}/ok')
                get(f'http://127.0.0.1:{app_port}/healthcheck')
                with self.assertRaises(urllib.error.HTTPError):
                    get(f'http://127.0.0.1:{app_port}/error')
                after = get(metrics_url)
                self.assertIn('monitoring_http_requests_total{status="200"} 1', after)
                self.assertIn('monitoring_http_requests_total{status="503"} 1', after)
                self.assertIn('monitoring_http_request_duration_seconds_count 2\n', after)
                start = lambda text: next(line for line in text.splitlines() if line.startswith('monitoring_process_start_time_seconds '))
                self.assertEqual(start(before), start(after))
                self.assertIn('monitoring_heap_limit_bytes ', after)
                self.assertNotIn('/ok', after)
            finally:
                process.terminate()
                process.wait(timeout=5)
                process.stderr.close()


if __name__ == '__main__':
    unittest.main()
