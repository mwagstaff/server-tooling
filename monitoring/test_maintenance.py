import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import sys

spec = importlib.util.spec_from_file_location('alert_maintenance', Path(__file__).with_name('maintenance.py'))
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class MaintenanceMappingTests(unittest.TestCase):
    def test_multi_service_deployment_maps_units_not_project_aliases(self):
        inventory = json.loads(Path(__file__).with_name('platform').joinpath('inventory.json').read_text())
        units = [s['unit'] for s in inventory['hosts']['sky']['services'] if s['name'].startswith('top-scores') and s['name'] != 'top-scores-web']
        names = maintenance.service_names(inventory, 'sky', units)
        self.assertEqual(len(names), len(units))
        self.assertIn('top-scores-scraper', names)
        self.assertNotIn('top-scores-web', names)
        self.assertEqual(maintenance.service_names(inventory, 'mini', ['com.train-track-planner.api']), ['train-track-planner'])
        self.assertEqual(maintenance.service_names(inventory, 'sky', ['com.aiops.api']), ['aiops'])

    def test_deployment_marks_only_selected_runtime_after_maintenance_succeeds(self):
        with patch.object(sys, 'argv', ['maintenance.py','--host','sky','--unit','com.top-scores.website','--planned-restart']), patch.object(maintenance.subprocess, 'run') as run:
            run.return_value = SimpleNamespace(stdout='{}')
            maintenance.main()
            self.assertEqual(run.call_count,2)
            self.assertIn('mini',run.call_args_list[0].args[0])
            self.assertIn('sky',run.call_args_list[1].args[0])
            code=run.call_args_list[1].kwargs['input']
            self.assertIn('for port in [19209]:',code)
            self.assertIn('endsAt=now+180',code)
            run.reset_mock()
            run.side_effect=RuntimeError('maintenance failed')
            with self.assertRaises(RuntimeError): maintenance.main()
            self.assertEqual(run.call_count,1)

    def test_unknown_units_cannot_broaden_to_host_wide_silence(self):
        with self.assertRaises(ValueError):
            maintenance.service_names({'hosts': {}}, 'sky', ['missing'])
        with self.assertRaises(ValueError):
            maintenance.service_names({'hosts': {}}, 'sky', [])


if __name__ == '__main__':
    unittest.main()
