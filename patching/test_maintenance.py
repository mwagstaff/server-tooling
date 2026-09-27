import importlib.util
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
    def test_busy_package_lock_defers_reboot_and_releases_before_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            locks = [str(Path(directory) / 'frontend'), str(Path(directory) / 'dpkg')]
            with patch.object(reboot, 'LOCKS', locks), patch.object(reboot.fcntl, 'lockf', side_effect=[BlockingIOError, None, None]), \
                 patch.object(reboot, 'record') as record, patch.object(reboot.time, 'sleep') as sleep, \
                 patch.object(reboot.subprocess, 'run') as run:
                reboot.main()
        sleep.assert_called_once_with(30)
        self.assertIn('delayed', record.call_args_list[0].args[1])
        run.assert_called_once_with(['systemctl', '--check-inhibitors=yes', 'reboot'], check=True)

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


if __name__ == '__main__':
    unittest.main()
