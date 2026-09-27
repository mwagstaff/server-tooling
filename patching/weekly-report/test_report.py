import json
from email import policy
from email.parser import BytesParser
from pathlib import Path
import tempfile
import time
import types
import unittest
from unittest.mock import patch

import events
import report
from email_format import html_report


class ReportTests(unittest.TestCase):
    def test_html_escapes_findings_and_keeps_logs_out_of_summary(self):
        text = ('Weekly upgrade — sky — REVIEW\nCompleted: 2026-09-27T11:00:00+00:00\n'
                '\nATTENTION\n- <script>untrusted</script>\n\nPACKAGES CHANGED\n'
                'caddy: 2.6.2 -> 2.11.4\n\nCURRENT STATUS\n'
                'caddy: active\n\nScope: OS checks\n\nUPGRADE LOG (last 60,000 characters)\nRAW_LOG_ONLY')
        html = html_report('REVIEW', text)
        self.assertIn('&lt;script&gt;', html)
        self.assertNotIn('<script>', html)
        self.assertNotIn('RAW_LOG_ONLY', html)
        self.assertIn('12:00:00 BST', html)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({'from': 'alerts@example.com', 'to': 'user@example.com'}))
            with patch('report.ROOT', root), patch('report.CONFIG', config):
                report.queue_report('REVIEW', text)
            message = BytesParser(policy=policy.default).parsebytes(next((root / 'outbox').glob('*.eml')).read_bytes())
        self.assertEqual(message.get_body(preferencelist=('html',)).get_content_type(), 'text/html')
        self.assertIn('RAW_LOG_ONLY', message.get_body(preferencelist=('plain',)).get_content())
        self.assertEqual(len(list(message.iter_attachments())), 1)

    def test_esm_security_gap_is_reported_even_with_no_apt_candidates(self):
        security = {'packages': [{'package': 'caddy', 'version': 'patched',
                                 'service_name': 'esm-apps', 'status': 'pending_attach'}], 'summary': {}}
        def result(args, **kwargs):
            if args[0] == 'pro':
                return 0, json.dumps(security), ''
            if args[0] == 'needrestart':
                return 0, 'NEEDRESTART-KSTA: 1', ''
            if args[:2] == ['systemctl', 'is-active']:
                return 0, 'active', ''
            return 0, '', ''
        apt = types.SimpleNamespace(Cache=lambda: [])
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            config.write_text(json.dumps({'user': 'test', 'uid': 1000, 'units': []}))
            with patch('report.CONFIG', config), patch('report.command', side_effect=result), \
                 patch.dict('sys.modules', {'apt': apt, 'apt_pkg': types.SimpleNamespace()}):
                warnings, sections = report.health()
        self.assertTrue(any('caddy' in warning and 'pending_attach' in warning for warning in warnings))

    def test_installed_upgraded_removed_packages(self):
        self.assertEqual(report.package_changes({'old': '1', 'same': '1', 'app': '1'},
                                               {'new': '2', 'same': '1', 'app': '2'}),
                         ['app: 1 -> 2', 'new: (new) -> 2', 'old: 1 -> (removed)'])

    def test_failed_upgrade_report_preserves_failure_and_changes(self):
        with patch('report.health', return_value=(['Restart required'], ['Current status'])), \
             patch('report.packages', return_value={'app': '2'}), \
             patch('report.command', return_value=(0, 'upgrade log', '')):
            status, body = report.build_report({'started': 100, 'packages': {'app': '1'}}, 'exit-code')
        self.assertEqual(status, 'FAILED')
        self.assertIn('app: 1 -> 2', body)
        self.assertIn('Restart required', body)
        self.assertIn('Upgrade service failed: exit-code', body)

    def test_delivery_failure_preserves_outbox_for_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({'smtp_host': 'mail.invalid', 'smtp_port': 2587}))
            (root / 'outbox').mkdir()
            mail = root / 'outbox/test.eml'
            mail.write_text('Subject: Test\n\nReport')
            with patch('report.ROOT', root), patch('report.CONFIG', config), \
                 patch('report.smtplib.SMTP', side_effect=OSError('offline')):
                with self.assertRaises(OSError):
                    report.deliver()
            self.assertTrue(mail.exists())

    def test_events_are_deduplicated_expired_and_atomically_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = time.time()
            events.record('upgrade', 'old', now - 31 * 86400, root)
            events.record('upgrade', 'started', now, root)
            events.record('upgrade', 'started', now, root)
            rows = json.loads((root / 'events.json').read_text())
            self.assertEqual(len(rows), 1)
            self.assertIn('detail="started"', (root / 'events.prom').read_text())
            self.assertEqual((root / 'events.prom').stat().st_mode & 0o777, 0o644)


if __name__ == '__main__':
    unittest.main()
