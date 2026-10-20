#!/usr/bin/env python3
"""Add the private AIOps receiver alongside existing platform notifications."""
from provision import ssh
import shlex

CODE=r'''
import json,pathlib,subprocess,datetime,urllib.request
root=pathlib.Path.home()/'.local/share/server-tooling-monitoring'
aiops=pathlib.Path.home()/'.local/share/aiops'
marker={'url':'http://127.0.0.1:19444/webhooks/alertmanager','token_file':str(aiops/'webhook-token')}
path=root/'alertmanager.json'
config=json.loads(path.read_text())
config['receivers']=[r for r in config['receivers'] if r['name']!='aiops']
config['receivers'].append({'name':'aiops','webhook_configs':[{
    'url':marker['url'],'send_resolved':True,'timeout':'10s',
    'http_config':{'authorization':{'credentials_file':marker['token_file']}}
}]})
routes=config['route'].setdefault('routes',[])
config['route']['routes']=[{'receiver':'aiops','matchers':['alertname!~"MonitoringWatchdog|AIOpsPipelineCanary"'],
    'continue':True,'group_wait':'0s','group_interval':'1m','repeat_interval':'4h'}]+[r for r in routes if r.get('receiver')!='aiops']
if not any(r.get('receiver')=='pushover' and not r.get('matchers') for r in config['route']['routes']):
    config['route']['routes'].append({'receiver':'pushover'})
config['route']['routes'].insert(0,{'receiver':'aiops','matchers':['alertname="AIOpsPipelineCanary"'],
    'group_wait':'0s','group_interval':'1m','repeat_interval':'1m'})
candidate=root/'alertmanager.aiops-candidate.json'
candidate.write_text(json.dumps(config,indent=2))
amtools=list((root/'bin').glob('alertmanager-*/amtool'))
if not amtools: raise RuntimeError('No amtool for validation')
subprocess.run([str(amtools[-1]),'check-config',str(candidate)],check=True)
backup=root/'backups'/('aiops-'+datetime.datetime.now().strftime('%Y%m%dT%H%M%S'))
backup.mkdir(parents=True)
(backup/'alertmanager.json').write_text(path.read_text())
candidate.replace(path)
try:
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:19093/-/reload',method='POST'),timeout=10) as response:
        if response.status!=200: raise RuntimeError('Alertmanager reload failed')
except Exception:
    path.write_text((backup/'alertmanager.json').read_text())
    raise
(root/'aiops.json').write_text(json.dumps(marker,indent=2))
print('Validated and reloaded AIOps receiver; existing notifications retained')
'''
for host in ['mini','sky']:
    print(host+': '+ssh(host,'python3 -c '+shlex.quote(CODE)).strip())
