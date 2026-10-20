import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from config import make_rules, write_json

PROMTOOL = os.environ.get('PROMTOOL') or shutil.which('promtool')


class RuleTests(unittest.TestCase):
    @unittest.skipUnless(PROMTOOL, 'Set PROMTOOL to run Prometheus rule scenarios')
    def test_alert_firing_recovery_traffic_guards_and_quantiles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_json(root / 'rules.json', make_rules([{'name': 'app'}], 'sky'))
            shutil.copy(Path(__file__).with_name('rules.test.json'), root / 'rules.test.json')
            subprocess.run([PROMTOOL, 'test', 'rules', 'rules.test.json'], cwd=root, check=True)

    @unittest.skipUnless(PROMTOOL, 'Set PROMTOOL to run Prometheus rule scenarios')
    def test_application_and_aiops_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            services=[{'name':n} for n in ['train-track-planner','tube-track-api','top-scores']]
            write_json(root/'rules.json', make_rules(services,'sky',aiops=True,monitor='mini'))
            shutil.copy(Path(__file__).with_name('coverage.test.json'),root/'coverage.test.json')
            subprocess.run([PROMTOOL,'test','rules','coverage.test.json'],cwd=root,check=True)
