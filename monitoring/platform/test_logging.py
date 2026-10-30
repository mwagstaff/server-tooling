import base64
import json
import os
import shutil
import subprocess
import tempfile
import http.server
import re
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from log_gateway import Handler
from log_config import alloy_config, loki_config
from configure_access_logs import render

class LoggingTests(unittest.TestCase):
    def test_logs_dashboard_uses_full_width_and_preserves_wrapping(self):
        from config import dashboards
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'logging.json').write_text('{}')
            dashboards(root)
            dashboard = json.loads((root / 'grafana/dashboards/logs.json').read_text())
            panel = dashboard['panels'][0]
            self.assertEqual(panel['gridPos'], {'x': 0, 'y': 0, 'w': 24, 'h': 24})
            self.assertTrue(panel['options']['wrapLogMessage'])
            self.assertEqual(panel['targets'][0]['expr'], '{host=~"$host",service=~"$service"}')

    def test_gateway_denies_missing_credentials_and_mutation_routes(self):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.allowed = {'127.0.0.1'}
        server.authorization = 'Basic ' + base64.b64encode(b'logs:fixture').decode()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for route, auth, method, expected in [('/ready', '', 'GET',403), ('/loki/api/v1/delete',server.authorization,'POST',404),('/config',server.authorization,'GET',404)]:
                request=urllib.request.Request(f'http://127.0.0.1:{server.server_port}'+route, headers={'Authorization':auth},method=method)
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(request)
                self.assertEqual(error.exception.code,expected)
                error.exception.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_redaction_expressions_capture_the_values_to_replace(self):
        config=alloy_config(Path('/home/operator/.local/share/server-tooling-monitoring'),'sky',[],'http://100.64.0.1:13101',True)
        expressions=re.findall(r'stage.replace \{.*?expression = `([^`]+)`',config,re.S)
        samples=['password=sample-secret','https://example.invalid/?token=sample','somebody@example.invalid','sk-abcdefghijklmnop','?token=sample']
        self.assertEqual(len(expressions),len(samples))
        for expression,sample in zip(expressions,samples):
            match=re.search(expression,sample)
            self.assertIsNotNone(match)
            self.assertEqual(match.group(1),sample)
        self.assertEqual(loki_config('/tmp/logging')['limits_config']['retention_period'],'336h')

    def test_caddy_render_is_repeatable_and_rejects_unknown_listener(self):
        initial=':4080 {\n respond "ok"\n}\n'
        self.assertEqual(render(render(initial)),render(initial))
        self.assertIn('request>headers delete',render(initial))
        with self.assertRaises(ValueError):render(':8080 {}')

    @unittest.skipUnless(os.environ.get('PROMTOOL') or shutil.which('promtool'), 'promtool required')
    def test_log_canary_stall_fires_and_recovers(self):
        from config import make_rules
        rules=make_rules([], 'sky', logging=True)
        rule=next(r for g in rules['groups'] for r in g['rules'] if r.get('alert')=='LogPipelineStalled')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'rules.json').write_text(json.dumps({'groups':[{'name':'logging','rules':[rule]}]}))
            fixture={'rule_files':['rules.json'],'evaluation_interval':'1m','tests':[{'interval':'1m',
                'input_series':[{'series':'logging_canary_timestamp_seconds{host="sky",service="logging"}','values':'0+0x10 660+60x5'}],
                'alert_rule_test':[{'eval_time':'9m','alertname':'LogPipelineStalled','exp_alerts':[{'exp_labels':dict(rule['labels'],host='sky',service='logging'),'exp_annotations':{'summary':'No recent end-to-end log canary from sky','description':'sky / logging: 540','runbook_url':rule['annotations']['runbook_url']}}]},
                    {'eval_time':'12m','alertname':'LogPipelineStalled','exp_alerts':[]}]}]}
            (root/'test.json').write_text(json.dumps(fixture))
            subprocess.run([os.environ.get('PROMTOOL') or shutil.which('promtool'),'test','rules','test.json'],cwd=root,check=True)

    def test_boot_plist_keeps_unprivileged_identity_and_command(self):
        import pwd
        from enable_boot import boot_plist
        user=pwd.getpwuid(os.getuid())
        value={'Label':'com.server-tooling.monitoring.loki',
               'ProgramArguments':['/usr/bin/env','GOMEMLIMIT=512MiB','/private/loki'],
               'UserName':'root','RunAtLoad':False,'KeepAlive':False}
        result=boot_plist(value,value['Label'],user)
        self.assertEqual(result['UserName'],user.pw_name)
        self.assertEqual(result['ProgramArguments'],value['ProgramArguments'])
        self.assertTrue(result['RunAtLoad'])
        self.assertTrue(result['KeepAlive'])
        with self.assertRaises(ValueError):boot_plist(value,'com.unrelated.service',user)
