import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from config import make_rules, write_json

class UpdaterRules(unittest.TestCase):
    def test_updater_alerts_are_separate_and_keep_target_identity(self):
        rules=[r for g in make_rules([{'name':'kidsplorers-events-worker'}],'mini',aiops=True,monitor='sky')['groups'] for r in g['rules']]
        updater=[r for r in rules if r.get('alert','').startswith('Ollama')]
        self.assertEqual(len(updater),3)
        for rule in updater:
            self.assertEqual(rule['labels']['service'],'kidsplorers-events-worker')
            self.assertEqual(rule['labels']['host'],'mini')
            self.assertEqual(rule['labels']['component'],'ollama-updater')
            self.assertEqual(rule['labels']['severity'],'warning')

    @unittest.skipUnless(os.environ.get('PROMTOOL') or shutil.which('promtool'),'promtool required')
    def test_overdue_resolution_missing_telemetry_and_worker_health(self):
        labels={'service':'kidsplorers-events-worker','host':'mini','component':'ollama-updater','severity':'warning'}
        rules=make_rules([{'name':'kidsplorers-events-worker'}],'mini',aiops=True,monitor='sky')
        all_rules=[r for g in rules['groups'] for r in g['rules']]
        by_name={r['alert']:r for r in all_rules if 'alert' in r}
        expected=lambda name:[{'exp_labels':labels,'exp_annotations':{**by_name[name]['annotations'],'description':'mini / kidsplorers-events-worker: 1'}}]
        tests={'rule_files':['rules.json'],'evaluation_interval':'1m','tests':[{
            'interval':'1m','input_series':[
                {'series':'aiops_service_healthy{service="kidsplorers-events-worker",host="mini"}','values':'1+0x12'},
                {'series':'up{kind="aiops",host="mini"}','values':'1+0x12'},
                {'series':'aiops_ollama_update_overdue{service="kidsplorers-events-worker",host="mini"}','values':'1+0x5 0+0x6'},
                {'series':'aiops_ollama_updater_healthy{service="kidsplorers-events-worker",host="mini"}','values':'1+0x12'}],
            'alert_rule_test':[
                {'eval_time':'2m','alertname':'OllamaUpdateOverdue','exp_alerts':[]},
                {'eval_time':'4m','alertname':'OllamaUpdateOverdue','exp_alerts':expected('OllamaUpdateOverdue')},
                {'eval_time':'8m','alertname':'OllamaUpdateOverdue','exp_alerts':[]},
                {'eval_time':'4m','alertname':'ServiceHealthFailing','exp_alerts':[]},
                {'eval_time':'4m','alertname':'OllamaUpdaterUnhealthy','exp_alerts':[]},
                {'eval_time':'4m','alertname':'OllamaUpdaterTelemetryMissing','exp_alerts':[]}]},
            {'interval':'1m','input_series':[{'series':'up{kind="aiops",host="mini"}','values':'1+0x5'}],
             'alert_rule_test':[{'eval_time':'4m','alertname':'OllamaUpdaterTelemetryMissing','exp_alerts':expected('OllamaUpdaterTelemetryMissing')}]}
        ]}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);write_json(root/'rules.json',rules);write_json(root/'test.json',tests)
            subprocess.run([os.environ.get('PROMTOOL') or shutil.which('promtool'),'test','rules','test.json'],cwd=root,check=True)
