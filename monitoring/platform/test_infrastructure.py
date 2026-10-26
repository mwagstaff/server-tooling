import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from config import make_rules

PROMTOOL = os.environ.get('PROMTOOL') or shutil.which('promtool')

class InfrastructureRulesTests(unittest.TestCase):
    @unittest.skipUnless(PROMTOOL, 'promtool required')
    def test_transient_failure_never_pages_but_sustained_failure_fires_and_clears(self):
        rules = make_rules([], 'sky', aiops=True, monitor='mini', logging=True)
        wanted = ['MonitoringNotificationFailures', 'MonitoringRuleFailures']
        selected = [r for g in rules['groups'] for r in g['rules'] if r.get('alert') in wanted]
        tests = []
        for rule in selected:
            notification = rule['alert'] == 'MonitoringNotificationFailures'
            metric = 'alertmanager_notifications_failed_total' if notification else 'prometheus_rule_evaluation_failures_total'
            labels = {'host':'mini','service':'alertmanager' if notification else 'prometheus'}
            if notification: labels.update(integration='webhook',reason='other')
            series = metric + '{' + ','.join(k+'="'+v+'"' for k,v in labels.items()) + '}'
            annotations = dict(rule['annotations'])
            annotations['summary'] = 'Sustained notification failures via webhook (other)' if notification else 'Monitoring rule evaluations failing'
            annotations['description'] = 'mini / '+labels['service']+': 2'
            expected = {'exp_labels':dict(labels,severity='critical'),'exp_annotations':annotations}
            tests.append({'interval':'1m','input_series':[{'series':series,'values':'0 1+0x14'}],
                          'alert_rule_test':[{'eval_time':str(n)+'m','alertname':rule['alert'],'exp_alerts':[]} for n in range(1,15)]})
            tests.append({'interval':'1m','input_series':[{'series':series,'values':'0+1x9 9+0x6'}],
                          'alert_rule_test':[{'eval_time':'7m','alertname':rule['alert'],'exp_alerts':[expected]},
                                             {'eval_time':'13m','alertname':rule['alert'],'exp_alerts':[]}]})
        self.run_rules(selected, tests)

    @unittest.skipUnless(PROMTOOL, 'promtool required')
    def test_successful_scrapes_with_missing_telemetry_alert(self):
        rules=make_rules([], 'sky', aiops=True, monitor='mini', logging=True)
        selected=[r for g in rules['groups'] for r in g['rules'] if r.get('alert') in ['AIOpsTelemetryMissing','LogTelemetryMissing']]
        series=[{'series':'up{host="sky",kind="aiops",job="aiops"}','values':'1+0x8'},
                {'series':'up{host="sky",service="logging",kind="logging",job="logs-health"}','values':'1+0x8'},
                {'series':'up{host="sky",service="logging",kind="logging",job="alloy"}','values':'1+0x8'}]
        assertions=[]
        for rule in selected:
            aiops=rule['alert'].startswith('AIOps')
            service='aiops' if aiops else 'logging'
            labels=dict(rule['labels'],host='sky',service=service,job='aiops' if aiops else 'logs-health',kind='aiops' if aiops else 'logging')
            annotations=dict(rule['annotations'],description='sky / '+service+': 1')
            assertions.append({'eval_time':'4m','alertname':rule['alert'],'exp_alerts':[{'exp_labels':labels,'exp_annotations':annotations}]})
        tests=[{'interval':'1m','input_series':series,'alert_rule_test':assertions}]
        complete=series+[{'series':name+'{host="sky",service="'+('logging' if name.startswith('logging') else 'aiops')+'"}','values':'1+0x8'} for name in [
            'logging_canary_timestamp_seconds','logging_disk_free_bytes','aiops_webhook_canary_timestamp_seconds','aiops_reconcile_timestamp_seconds',
            'aiops_queue_poll_timestamp_seconds','aiops_email_canary_timestamp_seconds','aiops_email_enabled','aiops_incident_oldest_seconds',
            'aiops_notifications_pending','aiops_notifications_failed']]
        tests.append({'interval':'1m','input_series':complete,'alert_rule_test':[{'eval_time':'4m','alertname':r['alert'],'exp_alerts':[]} for r in selected]})
        self.run_rules(selected,tests)

    @unittest.skipUnless(PROMTOOL, 'promtool required')
    def test_restart_loop_excludes_deploys_with_legacy_fallback(self):
        rules=make_rules([], 'sky')
        rule=next(r for g in rules['groups'] for r in g['rules'] if r.get('alert')=='RestartLoop')
        labels={'host':'sky','service':'fixture','instance':'fixture','kind':'runtime','job':'runtime-fixture'}
        suffix='{'+','.join(k+'="'+v+'"' for k,v in labels.items())+'}'
        starts={'series':'monitoring_process_start_time_seconds'+suffix,'values':'0 1 2 3 3 3 4 5 6 6 6'}
        expected={'exp_labels':dict(labels,severity='critical'), 'exp_annotations':dict(rule['annotations'],
                  summary='fixture restarted unexpectedly at least 3 times in 15 minutes',description='sky / fixture: 3')}
        self.run_rules([rule],[
            {'interval':'1m','input_series':[starts, {'series':'monitoring_unplanned_restarts_15m'+suffix,'values':'0 0 0 0 0 0 1 2 3 0 0'}],
             'alert_rule_test':[{'eval_time':'5m','alertname':'RestartLoop','exp_alerts':[]},
                                {'eval_time':'8m','alertname':'RestartLoop','exp_alerts':[expected]},
                                {'eval_time':'9m','alertname':'RestartLoop','exp_alerts':[]}]},
            {'interval':'1m','input_series':[starts],
             'alert_rule_test':[{'eval_time':'3m','alertname':'RestartLoop','exp_alerts':[expected]}]}])

    def run_rules(self,rules,tests):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'rules.json').write_text(json.dumps({'groups':[{'name':'fixture','rules':rules}]}))
            (root/'test.json').write_text(json.dumps({'rule_files':['rules.json'],'evaluation_interval':'1m','tests':tests}))
            subprocess.run([PROMTOOL,'test','rules','test.json'],cwd=root,check=True)
