import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('caddy_preflight', Path(__file__).parents[1] / 'validate-caddy-update.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class CaddyPreflightTests(unittest.TestCase):
    def test_rejects_candidate_that_cannot_load_config(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(preflight, 'LOG', Path(directory) / 'validation.log'), \
                 patch.object(preflight.subprocess, 'check_output', return_value='caddy\n'), \
                 patch.object(preflight.subprocess, 'run', side_effect=[
                     subprocess.CompletedProcess([], 0),
                     subprocess.CompletedProcess([], 1, '', 'configuration invalid')]):
                with self.assertRaisesRegex(RuntimeError, 'Caddy update refused'):
                    preflight.validate(Path('candidate.deb'))

    def test_other_packages_are_not_validated_as_caddy(self):
        with patch.object(preflight.subprocess, 'check_output', return_value='curl\n'), \
             patch.object(preflight.subprocess, 'run') as run:
            preflight.validate(Path('other.deb'))
            run.assert_not_called()
