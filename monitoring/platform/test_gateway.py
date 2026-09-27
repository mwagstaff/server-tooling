import http.server
import io
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).parent))
from gateway import Handler


class GatewayLoggingTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.allowed = {'127.0.0.1'}
        self.server.routes = {'/app/test': {'url': 'http://127.0.0.1:1/metrics?secret=hidden'}}
        self.server.opener = Mock()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self):
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{self.server.server_port}/app/test') as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read()

    def failure(self, error):
        self.server.opener.open.side_effect = error
        with self.assertLogs('metrics_gateway', level='WARNING') as logs:
            status, _ = self.request()
        self.assertEqual(status, 502)
        self.assertNotIn('hidden', ''.join(logs.output))
        record = json.loads(logs.records[0].getMessage())
        self.assertEqual(record['route'], '/app/test')
        self.assertEqual(record['event'], 'upstream_failure')
        self.assertGreaterEqual(record['duration_ms'], 0)
        return record

    def test_http_status_without_secret_reason_or_body(self):
        error = urllib.error.HTTPError('http://hidden', 429, 'hidden', {}, io.BytesIO(b'hidden'))
        record = self.failure(error)
        self.assertEqual(record['upstream_status'], 429)
        self.assertEqual(record['stage'], 'connect')

    def test_connection_refusal_and_timeout(self):
        record = self.failure(urllib.error.URLError(ConnectionRefusedError(111, 'hidden')))
        self.assertEqual(record['cause_type'], 'ConnectionRefusedError')
        self.assertEqual(record['errno'], 111)
        record = self.failure(TimeoutError('hidden'))
        self.assertEqual(record['error_type'], 'TimeoutError')

    def response(self, data, headers=None):
        response = Mock(status=200, headers=headers or {})
        response.read.return_value = data
        self.server.opener.open.return_value.__enter__ = Mock(return_value=response)
        self.server.opener.open.return_value.__exit__ = Mock(return_value=False)
        return response

    def test_truncated_body(self):
        self.response(b'x', {'Content-Length': '20'})
        with self.assertLogs('metrics_gateway') as logs:
            self.assertEqual(self.request()[0], 502)
        record = json.loads(logs.records[0].getMessage())
        self.assertEqual(record['error_type'], 'IncompleteRead')
        self.assertEqual(record['stage'], 'read')
        self.assertEqual(record['missing_bytes'], 19)

    def test_response_limit(self):
        self.response(b'12345')
        with patch('gateway.MAX_RESPONSE_BYTES', 4), self.assertLogs('metrics_gateway') as logs:
            self.assertEqual(self.request()[0], 502)
        self.assertEqual(json.loads(logs.records[0].getMessage())['event'], 'response_too_large')

    def test_healthy_requests_quiet_and_slow_requests_logged(self):
        self.response(b'metric 1\n')
        with self.assertNoLogs('metrics_gateway'):
            self.assertEqual(self.request(), (200, b'metric 1\n'))
        with patch('gateway.SLOW_RESPONSE_SECONDS', 0), self.assertLogs('metrics_gateway') as logs:
            self.assertEqual(self.request()[0], 200)
        self.assertEqual(json.loads(logs.records[0].getMessage())['event'], 'slow_response')

    def test_client_disconnect_does_not_send_second_response(self):
        self.response(b'metric 1\n')
        handler = object.__new__(Handler)
        handler.server = self.server
        handler.client_address = ('127.0.0.1', 1)
        handler.path = '/app/test'
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        handler.send_error = Mock()
        handler.wfile = Mock()
        handler.wfile.write.side_effect = BrokenPipeError(32, 'hidden')
        with self.assertLogs('metrics_gateway') as logs:
            handler.do_GET()
        handler.send_response.assert_called_once_with(200)
        handler.send_error.assert_not_called()
        self.assertEqual(json.loads(logs.records[0].getMessage())['event'], 'client_disconnect')
