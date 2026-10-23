import importlib.util
import json
from pathlib import Path
import unittest

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

    def test_unknown_units_cannot_broaden_to_host_wide_silence(self):
        with self.assertRaises(ValueError):
            maintenance.service_names({'hosts': {}}, 'sky', ['missing'])
        with self.assertRaises(ValueError):
            maintenance.service_names({'hosts': {}}, 'sky', [])


if __name__ == '__main__':
    unittest.main()
