#!/usr/bin/env python3
"""Exercise the real runner against a disposable Sky user service, then remove it."""
import json
from pathlib import Path
import subprocess

runner = (Path(__file__).resolve().parents[1] / 'runner.py').read_text()
script = r'''
import json,os,pathlib,shutil,subprocess,tempfile,time,uuid
root=pathlib.Path(tempfile.mkdtemp(prefix='aiops-recovery-test-'))
unit=pathlib.Path.home()/'.config/systemd/user/com.aiops.recovery-test.service'
if unit.exists(): raise RuntimeError('Test unit already exists; inspect it before proceeding')
environment={**os.environ,'AIOPS_STATE_DIR':str(root)}
def systemctl(*args):
    return subprocess.run(['systemctl','--user',*args],check=True,capture_output=True,text=True)
def request(operation,action_id=None):
    payload={'operation':operation,'service':'disposable-test'}
    if action_id: payload['actionId']=action_id
    result=subprocess.run(['/usr/bin/python3',str(root/'runner.py')],input=json.dumps(payload),
        env=environment,check=True,capture_output=True,text=True)
    return json.loads(result.stdout)
try:
    (root/'runner.py').write_text(RUNNER_SOURCE)
    (root/'fixture.py').write_text("""from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'disposable AIOps recovery fixture')
HTTPServer(('127.0.0.1',19445),Handler).serve_forever()
""")
    unit.write_text('[Unit]\nDescription=Disposable AIOps recovery verification\n[Service]\n'
        +'ExecStart=/usr/bin/python3 '+str(root/'fixture.py')+'\n')
    systemctl('daemon-reload')
    item={'name':'disposable-test','unit':'com.aiops.recovery-test','directory':str(root),
        'healthUrl':'http://127.0.0.1:19445/','logs':[],'group':'disposable-test',
        'autoActions':['restart'],'approvalActions':[]}
    (root/'runner.json').write_text(json.dumps({'services':[item],'cooldownSeconds':900}))
    assert request('inspect')['healthy'] is False
    action_id='live_test_'+uuid.uuid4().hex
    result=request('restart',action_id)
    assert result['ok'],result
    samples=[]
    for _ in range(3):
        time.sleep(1)
        samples.append(request('inspect')['healthy'])
    assert all(samples),samples
    first_pid=systemctl('show','com.aiops.recovery-test.service','--property=MainPID','--value').stdout.strip()
    assert request('restart',action_id)==result
    second_pid=systemctl('show','com.aiops.recovery-test.service','--property=MainPID','--value').stdout.strip()
    assert first_pid==second_pid,'Repeated delivery restarted the process'
    cooldown=request('restart','new_test_'+uuid.uuid4().hex)
    assert cooldown['ok'] is False and 'cooldown' in cooldown['reason']
    print(json.dumps({'realServiceRecovery':True,'healthySamples':samples,
        'duplicateActionDidNotRestart':True,'cooldownEnforced':True}))
finally:
    subprocess.run(['systemctl','--user','stop','com.aiops.recovery-test.service'],capture_output=True)
    unit.unlink(missing_ok=True)
    systemctl('daemon-reload')
    shutil.rmtree(root)
'''
subprocess.run(['ssh', '-o', 'BatchMode=yes', 'sky', 'python3', '-'],
               input='RUNNER_SOURCE='+repr(runner)+'\n'+script, text=True, check=True)
