import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runner', Path(__file__).parents[1] / 'runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        runner.ROOT = Path(self.temp.name)
        self.item = {'name': 'fixture', 'group': 'fixture', 'unit': 'fixture', 'autoActions': ['restart'],
                     'approvalActions': ['redeploy'], 'directory': self.temp.name, 'healthUrl': 'http://localhost'}
        self.config = {'services': [self.item], 'cooldownSeconds': 900}
        self.request = {'service': 'fixture', 'operation': 'restart', 'actionId': 'fixture-action-1'}

    def tearDown(self):
        self.temp.cleanup()

    def test_probe_drains_streamed_response_and_rejects_truncated_body(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from threading import Thread, Event
        complete = Event()
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', '131072')
                self.end_headers()
                self.wfile.write(b'x' * 65536)
                self.wfile.flush()
                if self.path == '/truncated':
                    return
                runner.time.sleep(0.02)
                self.wfile.write(b'x' * 65536)
                complete.set()
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.assertTrue(runner.probe(f'http://127.0.0.1:{server.server_port}/')['ok'])
            self.assertTrue(complete.is_set())
            self.assertFalse(runner.probe(f'http://127.0.0.1:{server.server_port}/truncated')['ok'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_event_logs_require_valid_explicit_event_time(self):
        rows = runner.event_logs('old startup\n2026-10-26T21:14:34.123Z failed\n2026-99-26T21:14:34.123Z invalid\n', 'service.log')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['at'], '2026-10-26T21:14:34.123Z')
        self.assertEqual(rows[0]['timestampSource'], 'application')

    def test_planner_evidence_omits_payloads_and_preserves_event_times(self):
        path = Path(self.temp.name) / '.local/share/train-track-planner/planner'
        path.mkdir(parents=True)
        (path / 'ingestion-state.json').write_text(json.dumps({'lastCheckAt': '2026-10-26T21:14:34.123Z',
            'lastErrorCode': 'INVALID_DELIVERY', 'active': {'currentSequence': '001', 'metadata': {'private': 'payload'}}, 'remote': {'secret': 'hidden'}}))
        with patch.object(runner.Path, 'home', return_value=Path(self.temp.name)):
            evidence = runner.planner_ingestion_evidence()
        self.assertEqual(evidence['lastErrorCode'], 'INVALID_DELIVERY')
        self.assertEqual(evidence['active']['currentSequence'], '001')
        self.assertNotIn('payload', json.dumps(evidence))
        self.assertNotIn('hidden', json.dumps(evidence))

    def test_readiness_preserves_503_dependency_body_and_omits_unknown_fields(self):
        from io import BytesIO
        from urllib.error import HTTPError
        body = {'ready': False, 'checkedAt': '2026-10-28T12:46:22.000Z',
                'mongo': {'healthy': True}, 'feed': {'healthy': False, 'state': 'subscribed',
                'messageAgeSeconds': 450, 'credentials': 'must-not-escape'}, 'extra': 'private'}
        response = HTTPError('http://localhost/health/ready', 503, 'Unavailable', {}, BytesIO(json.dumps(body).encode()))
        with patch.object(runner.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = response
            result = runner.loading_health_evidence('http://localhost/health/ready')
        self.assertEqual(result['status'], 503)
        self.assertFalse(result['ready'])
        self.assertEqual(result['feed']['messageAgeSeconds'], 450)
        self.assertTrue(result['mongo']['healthy'])
        self.assertNotIn('must-not-escape', json.dumps(result))
        self.assertNotIn('private', json.dumps(result))

    def test_event_logs_accept_json_event_times_not_collected_times(self):
        rows = runner.event_logs('{"ts":"2026-10-28T12:46:22.000Z","event":"http_request"}\n{"message":"undated"}', 'service.log')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['timestampSource'], 'application')

    def test_worker_inspection_matches_failed_dashboard_job(self):
        from io import BytesIO
        now = runner.datetime.now(runner.timezone.utc).isoformat()
        data = {'running': False, 'lastRun': {'startedAt': now, 'finishedAt': now, 'ok': 26, 'failed': 1},
                'sources': {'barking-dagenham': {'lastRunAt': now, 'lastError': 'Invalid model JSON', 'items': 'private'}}}
        item = {**self.item, 'name': 'kidsplorers-events-worker'}
        for failed in (1, 0):
            data['lastRun']['failed'] = failed
            with patch.object(runner.urllib.request, 'build_opener') as opener, \
                    patch.object(runner, 'status', return_value={'active': True}), \
                    patch.object(runner, 'probe', return_value={'ok': True}), \
                    patch.object(runner, 'ollama_update_evidence', return_value={'checks': {'ollamaUpdateHealthy': True}}):
                opener.return_value.open.return_value = BytesIO(json.dumps(data).encode())
                result = runner.inspect(item)
            self.assertEqual(result['healthy'], failed == 0)
            self.assertEqual(result['workerHealth']['checks']['dailyJobSucceeded'], failed == 0)
            self.assertNotIn('private', json.dumps(result))
            self.assertFalse((runner.ROOT / 'worker-last-run.json').exists())
        with patch.object(runner.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = OSError('offline')
            self.assertFalse(runner.worker_health_evidence('http://localhost')['checks']['jobEvidenceAvailable'])

    def test_updater_checks_cover_stale_failed_overdue_and_interrupted_states(self):
        path = Path(self.temp.name) / '.local/share/ollama-updater'
        path.mkdir(parents=True)
        now = 2000000
        healthy = {'installedVersion': '0.40.12', 'latestVersion': '0.40.13', 'lastCheckAt': now,
                   'phase': 'idle', 'healthError': None}
        with patch.object(runner.Path, 'home', return_value=Path(self.temp.name)):
            self.assertFalse(runner.ollama_update_evidence(now)['checks']['ollamaUpdateStateReadable'])
            for extra, failed in [({}, None), ({'lastCheckAt': now-72*3600}, 'ollamaUpdateCheckFresh'),
                    ({'healthError': 'smoke failed'}, 'ollamaUpdateHealthy'),
                    ({'pendingSince': now-14*86400}, 'ollamaUpdateTimely'),
                    ({'phase': 'rollback', 'transactionStartedAt': now-3000}, 'ollamaUpdateNotStuck')]:
                (path/'state.json').write_text(json.dumps({**healthy, **extra}))
                checks = runner.ollama_update_evidence(now)['checks']
                if failed: self.assertFalse(checks[failed])
                else: self.assertTrue(all(checks.values()))

    def test_worker_json_time_is_event_evidence(self):
        rows = runner.event_logs('{"time":"2026-10-29T01:46:08.850Z","msg":"source failed"}', 'worker.log')
        self.assertEqual(rows[0]['at'], '2026-10-29T01:46:08.850Z')

    def test_reject_unknown_service_and_command(self):
        with self.assertRaises(ValueError):
            runner.handle({**self.request, 'service': 'fixture; rm -rf /'}, self.config)
        with self.assertRaises(ValueError):
            runner.handle({**self.request, 'operation': 'shell'}, self.config)

    def test_launchagent_status_finds_gui_and_headless_user_services(self):
        for domain, state in [('gui/501', 'running'), ('user/501', 'running'),
                              ('user/501', 'waiting')]:
            with self.subTest(domain=domain, state=state):
                def launchctl(args, timeout=15):
                    loaded = args == ['launchctl', 'print', domain + '/fixture']
                    return {'code': 0 if loaded else 125,
                            'stdout': f'state = {state}' if loaded else '', 'stderr': ''}
                with patch.object(runner.platform, 'system', return_value='Darwin'), \
                        patch.object(runner.os, 'getuid', return_value=501), \
                        patch.object(runner, 'command', side_effect=launchctl):
                    self.assertEqual(runner.status(self.item)['active'], state == 'running')

    def test_launchagent_restart_targets_the_loaded_service_domain(self):
        for domain in ['gui/501', 'user/501']:
            with self.subTest(domain=domain):
                def launchctl(args, timeout=15):
                    if args[:2] == ['launchctl', 'print']:
                        return {'code': 0 if args[2] == domain + '/fixture' else 125,
                                'stdout': 'state = waiting', 'stderr': ''}
                    return {'code': 0, 'stdout': '', 'stderr': ''}
                with patch.object(runner.platform, 'system', return_value='Darwin'), \
                        patch.object(runner.os, 'getuid', return_value=501), \
                        patch.object(runner, 'command', side_effect=launchctl) as command:
                    self.assertEqual(runner.restart(self.item)['code'], 0)
                    command.assert_called_with(['launchctl', 'kickstart', '-k', domain + '/fixture'], 90)

    def test_missing_launchagent_is_unhealthy_and_cannot_be_restarted(self):
        with patch.object(runner.platform, 'system', return_value='Darwin'), \
                patch.object(runner.os, 'getuid', return_value=501), \
                patch.object(runner, 'command', return_value={'code': 113, 'stdout': '', 'stderr': ''}) as command:
            self.assertFalse(runner.status(self.item)['active'])
            with self.assertRaisesRegex(ValueError, 'not loaded'):
                runner.restart(self.item)
            self.assertTrue(all(c.args[0][:2] == ['launchctl', 'print'] for c in command.call_args_list))

    def test_launchagent_prefers_gui_when_both_domains_have_the_service(self):
        with patch.object(runner.platform, 'system', return_value='Darwin'), \
                patch.object(runner.os, 'getuid', return_value=501), \
                patch.object(runner, 'command', return_value={'code': 0, 'stdout': 'state = running', 'stderr': ''}) as command:
            self.assertTrue(runner.status(self.item)['active'])
            runner.restart(self.item)
            self.assertTrue(all('user/501/fixture' not in c.args[0] for c in command.call_args_list))
            command.assert_called_with(['launchctl', 'kickstart', '-k', 'gui/501/fixture'], 90)

    def test_system_daemon_keeps_its_restricted_admin_helper(self):
        item = {**self.item, 'scope': 'system', 'adminHelper': '/usr/local/sbin/fixture-admin'}
        with patch.object(runner.platform, 'system', return_value='Darwin'), \
                patch.object(runner, 'command', return_value={'code': 0, 'stdout': 'state = running', 'stderr': ''}) as command:
            self.assertTrue(runner.status(item)['active'])
            command.assert_called_with(['launchctl', 'print', 'system/fixture'])
            runner.restart(item)
            command.assert_called_with(['sudo', '-n', item['adminHelper'], 'restart', 'fixture'], 90)

    def test_linux_keeps_systemd_status_and_restart(self):
        with patch.object(runner.platform, 'system', return_value='Linux'), \
                patch.object(runner, 'command', return_value={'code': 0, 'stdout': 'active\n', 'stderr': ''}) as command:
            self.assertTrue(runner.status(self.item)['active'])
            command.assert_called_with(['systemctl', '--user', 'is-active', 'fixture.service'])
            runner.restart(self.item)
            command.assert_called_with(['systemctl', '--user', 'restart', 'fixture.service'], 90)

    def test_health_checks_are_read_only_and_include_public_failures(self):
        self.item['publicUrl'] = 'https://example.test'
        (runner.ROOT / 'PAUSED').touch()
        with patch.object(runner, 'status', return_value={'active': True}), \
                patch.object(runner, 'probe', side_effect=lambda url, *args: {'ok': url != 'https://example.test'}), \
                patch.object(runner, 'restart') as restart, patch.object(runner, 'inspect') as inspect:
            result = runner.handle({'service': '__host__', 'operation': 'health_all'}, self.config)
        row = result['services'][0]
        self.assertEqual(row['status'], 'unhealthy')
        self.assertFalse(row['checks']['public'])
        self.assertIn('checkedAt', row)
        restart.assert_not_called()
        inspect.assert_not_called()

    def test_failed_service_check_does_not_hide_other_services(self):
        other = {**self.item, 'name': 'other'}
        with patch.object(runner, 'status', side_effect=lambda item: {'active': item['name'] != 'fixture'}), \
                patch.object(runner, 'probe', return_value={'ok': True}), \
                    patch.object(runner, 'ollama_update_evidence', return_value={'checks': {'ollamaUpdateHealthy': True}}):
            result = runner.handle({'service': '__host__', 'operation': 'health_all'}, {'services': [self.item, other]})
        self.assertEqual([r['status'] for r in result['services']], ['unhealthy', 'healthy'])

    def test_worker_last_observed_result_survives_process_restart(self):
        from datetime import datetime, timezone
        stamp=datetime.now(timezone.utc).isoformat()
        data={'running':False,'lastRun':{'startedAt':stamp,'finishedAt':stamp,'ok':27,'failed':0}}
        self.assertTrue(all(runner.worker_health(data).values()))
        self.assertTrue(all(runner.worker_health({'running':False,'lastRun':None}).values()))
        data['lastRun']['failed']=1
        self.assertFalse(runner.worker_health(data)['dailyJobSucceeded'])
        self.assertFalse(runner.worker_health({'running':False})['dailyJobSucceeded'])

    def test_worker_checks_detect_failed_missed_and_stuck_daily_jobs(self):
        from datetime import datetime, timezone
        now=datetime(2026,10,20,12,tzinfo=timezone.utc)
        healthy={'running':False,'lastRun':{'startedAt':'2026-10-20T00:00:00Z','finishedAt':'2026-10-20T01:00:00Z','ok':27,'failed':0}}
        self.assertTrue(all(runner.worker_checks(healthy,now).values()))
        healthy['lastRun']['failed']=1
        self.assertFalse(runner.worker_checks(healthy,now)['dailyJobSucceeded'])
        self.assertFalse(runner.worker_checks({},now)['dailyJobRecent'])
        healthy['running']=True
        self.assertFalse(runner.worker_checks(healthy,now)['dailyJobCompleted'])

    def test_idempotent_action_and_cooldown(self):
        with patch.object(runner, 'inspect', return_value={'healthy': False}), patch.object(runner, 'restart', return_value={'code': 0}) as restart:
            self.assertTrue(runner.handle(self.request, self.config)['ok'])
            self.assertTrue(runner.handle(self.request, self.config)['ok'])
            self.assertEqual(restart.call_count, 1)
            second = runner.handle({**self.request, 'actionId': 'fixture-action-2'}, self.config)
            self.assertIn('cooldown', second['reason'])

    def test_crash_never_replays_unknown_action(self):
        with patch.object(runner, 'inspect', return_value={'healthy': False}), patch.object(runner, 'restart', side_effect=RuntimeError('crash')):
            with self.assertRaises(RuntimeError):
                runner.handle(self.request, self.config)
        with patch.object(runner, 'restart') as restart:
            self.assertIn('unknown', runner.handle(self.request, self.config)['reason'])
            restart.assert_not_called()

    def test_target_pause(self):
        (runner.ROOT / 'PAUSED').touch()
        self.assertIn('paused', runner.handle(self.request, self.config)['reason'])

    def test_healthy_guard(self):
        with patch.object(runner, 'inspect', return_value={'healthy': True}), patch.object(runner, 'restart') as restart:
            self.assertIn('already healthy', runner.handle(self.request, self.config)['reason'])
            restart.assert_not_called()

    def test_dependency_failure(self):
        self.item['dependencyProbes'] = {'api': 'http://localhost'}
        with patch.object(runner, 'probe', return_value={'ok': False}):
            self.assertIn('Dependency', runner.handle(self.request, self.config)['reason'])

    def test_release_path_protects_secrets_and_traversal(self):
        for path in ['../secret.js', '/etc/passwd', '.env.local', 'certs/key.json', 'var/data.json', 'node_modules/pkg/index.js']:
            with self.assertRaises(ValueError):
                runner.safe_relative(path)

    def test_all_release_hashes_verified_before_any_write(self):
        base = runner.ROOT / 'releases/fixture'
        (base / 'files').mkdir(parents=True)
        (base / 'files/server.js').write_text('new')
        live = runner.ROOT / 'server.js'
        live.write_text('old')
        (base / 'manifest.json').write_text(json.dumps({'directory': str(runner.ROOT), 'files': {'server.js': 'wronghash'}}))
        with self.assertRaises(ValueError):
            runner.restore(self.item)
        self.assertEqual(live.read_text(), 'old')


if __name__ == '__main__':
    unittest.main()
