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

    def test_reject_unknown_service_and_command(self):
        with self.assertRaises(ValueError):
            runner.handle({**self.request, 'service': 'fixture; rm -rf /'}, self.config)
        with self.assertRaises(ValueError):
            runner.handle({**self.request, 'operation': 'shell'}, self.config)

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
                patch.object(runner, 'probe', return_value={'ok': True}):
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
