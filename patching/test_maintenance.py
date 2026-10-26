import importlib.util
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE / 'weekly-report'))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SOURCE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reboot = load('weekly_reboot', 'weekly-reboot.py')
installer = load('maintenance_installer', 'install-maintenance.py')
reports = load('report_installer', 'install-upgrade-report.py')


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        window = patch.object(reboot, 'in_reboot_window', return_value=True)
        self.window = window.start()
        self.addCleanup(window.stop)
        maintenance = patch.object(reboot, 'begin_alert_maintenance')
        self.maintenance = maintenance.start()
        self.addCleanup(maintenance.stop)

    def test_daytime_request_does_not_assess_or_reboot(self):
        self.window.return_value = False
        with patch.object(reboot, 'record') as record, patch.object(reboot, 'reboot_needed') as needed, \
             patch.object(reboot.subprocess, 'run') as run:
            reboot.main(required_only=True)
            needed.assert_not_called()
            run.assert_not_called()
            self.assertIn('deferred', record.call_args.args[1])

    def test_assessment_cannot_run_reboot_past_window(self):
        self.window.side_effect = [True, False]
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(reboot, 'LOCKS', [str(Path(directory) / 'dpkg')]), \
             patch.object(reboot, 'reboot_needed', return_value=True), \
             patch.object(reboot, 'record'), patch.object(reboot.subprocess, 'run') as run:
            reboot.main(required_only=True)
            run.assert_not_called()

    def test_reboot_required_flag(self):
        with patch.object(reboot.Path, 'exists', return_value=True), patch.object(reboot.subprocess, 'run') as run:
            self.assertTrue(reboot.reboot_needed())
            run.assert_not_called()

    def test_restart_assessment(self):
        for output, expected in [('NEEDRESTART-KSTA: 1\n', False),
                                 ('NEEDRESTART-KSTA: 2\n', True),
                                 ('NEEDRESTART-KSTA: 3\n', True),
                                 ('NEEDRESTART-SVC: dbus.service\n', True),
                                 ('NEEDRESTART-SESS: user @ manager\n', True),
                                 ('NEEDRESTART-CONT: container\n', True),
                                 ('NEEDRESTART-UCSTA: 2\n', True)]:
            with self.subTest(output=output), patch.object(reboot.Path, 'exists', return_value=False), \
                 patch.object(reboot.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output)):
                self.assertEqual(reboot.reboot_needed(), expected)

    def test_conditional_reboot_and_failed_assessment(self):
        for needed in (False, True, subprocess.CalledProcessError(1, 'needrestart')):
            with self.subTest(needed=needed), tempfile.TemporaryDirectory() as directory:
                with patch.object(reboot, 'LOCKS', [str(Path(directory) / 'dpkg')]), \
                     patch.object(reboot, 'record'), patch.object(reboot.subprocess, 'run') as run, \
                     patch.object(reboot, 'reboot_needed', side_effect=[needed]):
                    if isinstance(needed, Exception):
                        with self.assertRaises(subprocess.CalledProcessError):
                            reboot.main(required_only=True)
                        run.assert_not_called()
                    else:
                        reboot.main(required_only=True)
                        self.assertEqual(run.call_count, int(needed))
                        self.assertEqual(self.maintenance.call_count, int(needed))
                        self.maintenance.reset_mock()

    def test_busy_package_lock_defers_reboot_and_releases_before_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            locks = [str(Path(directory) / 'frontend'), str(Path(directory) / 'dpkg')]
            with patch.object(reboot, 'LOCKS', locks), patch.object(reboot.fcntl, 'lockf', side_effect=[BlockingIOError, None, None]), \
                 patch.object(reboot, 'record') as record, patch.object(reboot.time, 'sleep') as sleep, \
                 patch.object(reboot.subprocess, 'run') as run:
                reboot.main()
        sleep.assert_called_once_with(30)
        self.assertIn('delayed', record.call_args_list[0].args[1])
        run.assert_called_once_with(['systemctl', '--check-inhibitors=yes', 'reboot'], check=True, capture_output=True, text=True)

    def test_logged_in_users_defer_without_masking_other_reboot_failures(self):
        for detail, deferred in [('Please retry operation after closing inhibitors and logging out other users.', True),('D-Bus unavailable', False)]:
            with tempfile.TemporaryDirectory() as directory, patch.object(reboot, 'LOCKS', [str(Path(directory)/'lock')]), patch.object(reboot, 'record') as record, patch.object(reboot.subprocess, 'run', side_effect=subprocess.CalledProcessError(1,'systemctl',stderr=detail)):
                if deferred:
                    reboot.main()
                    self.assertIn('deferred', record.call_args.args[1])
                else:
                    with self.assertRaises(subprocess.CalledProcessError): reboot.main()

    def test_busy_package_lock_timeout_never_reboots(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(reboot, 'LOCKS', [str(Path(directory) / 'dpkg')]), \
                 patch.object(reboot.fcntl, 'lockf', side_effect=BlockingIOError), \
                 patch.object(reboot.time, 'monotonic', side_effect=[0, 1800]), \
                 patch.object(reboot, 'record'), patch.object(reboot.subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'skipped'):
                    reboot.main()
                run.assert_not_called()

    def test_new_host_without_inventory_or_tailscale_gets_report(self):
        remote_args = []
        def ssh(host, args, **kwargs):
            if args[:2] == ['python3', '-c']:
                return subprocess.CompletedProcess(args, 0, '{"home":"/home/test","os":"linux","host":"new-host"}')
            if 'any(p.is_file()' in str(args):
                return subprocess.CompletedProcess(args, 0, 'True')
            if args == ['mktemp', '-d']:
                return subprocess.CompletedProcess(args, 0, '/tmp/stage')
            remote_args.append(args)
            return subprocess.CompletedProcess(args, 0, '')
        with patch.object(sys, 'argv', ['install-upgrade-report.py', 'new-host']), \
             patch.object(reports, 'ssh', side_effect=ssh), patch.object(reports, 'run'), \
             patch.object(reports, 'vault_items') as vault, patch.dict('os.environ', {}, clear=True):
            reports.main()
        vault.assert_not_called()
        root_install = next(args for args in remote_args if args[:3] == ['sudo', '-n', 'python3'])
        self.assertEqual(root_install[-1], '[]')
        self.assertEqual(root_install[-2], 'new-host')

    def test_new_host_without_caddy_skips_repository_migration(self):
        commands = []
        def ssh(host, args, **kwargs):
            return subprocess.CompletedProcess(args, 0, '/tmp/stage' if args == ['mktemp', '-d'] else '')
        with patch.object(sys, 'argv', ['install-maintenance.py', 'new-host']), \
             patch.object(installer, 'ssh', side_effect=ssh), \
             patch.object(installer, 'run', side_effect=lambda args: commands.append(args)):
            installer.main()
        self.assertTrue(any('install-upgrade-report.py' in str(args) for args in commands))
        self.assertFalse(any('configure-caddy-updates.py' in str(args) for args in commands))


class AlertMaintenanceTests(unittest.TestCase):
    def test_configured_hook_runs_before_reboot_and_failure_is_logged(self):
        for failure in (False, True):
            with self.subTest(failure=failure), patch.object(reboot.Path, 'exists', return_value=True), \
                 patch.object(reboot.Path, 'read_text', return_value='{"stateDir":"/home/test/.local/share/aiops"}'), \
                 patch.object(reboot.subprocess, 'run', side_effect=RuntimeError('unreachable') if failure else None) as run, \
                 patch.object(reboot, 'record') as record:
                reboot.begin_alert_maintenance()
                self.assertIn('--host-wide', run.call_args.args[0])
                self.assertIn('600', run.call_args.args[0])
                self.assertEqual(record.called, failure)


class RebootWindowTests(unittest.TestCase):
    def test_uk_window_in_summer_winter_and_dst_transition_days(self):
        for day, start in [('2026-10-20', 3), ('2026-12-20', 4),
                           ('2026-03-29', 3), ('2026-10-25', 4)]:
            for hour, minute, expected in [(start - 1, 59, False), (start, 0, True),
                                            (start, 59, True), (start + 1, 0, False)]:
                with self.subTest(day=day, hour=hour, minute=minute):
                    now = datetime.fromisoformat(day).replace(hour=hour, minute=minute, tzinfo=timezone.utc)
                    self.assertEqual(reboot.in_reboot_window(now), expected)


if __name__ == '__main__':
    unittest.main()
