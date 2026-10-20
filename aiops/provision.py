#!/usr/bin/env python3
"""Provision private AIOps state and restricted cross-host SSH. Does not restart apps."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parent
HOSTS = {
    'mini': {'home': '/Users/mwagstaff', 'ip': '100.83.63.95', 'dns': 'mikes-mac-mini.dog-rattlesnake.ts.net',
             'node': '/opt/homebrew/bin/node', 'python': '/usr/bin/python3'},
    'sky': {'home': '/home/mwagstaff', 'ip': '100.88.174.85', 'dns': 'sky.dog-rattlesnake.ts.net',
            'node': '/home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node', 'python': '/usr/bin/python3'}
}


def ssh(host, code, data=None):
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host, code],
                            input=data, capture_output=True, text=True, check=True)
    return result.stdout


def write(host, path, content, mode=0o600):
    code = f"import pathlib,sys,os;p=pathlib.Path({path!r});p.parent.mkdir(parents=True,exist_ok=True);p.write_text(sys.stdin.read());p.chmod({mode})"
    ssh(host, 'python3 -c ' + shlex.quote(code), content)


def services():
    inventory=json.loads((REPO/'monitoring/platform/inventory.json').read_text())
    projects=json.loads((REPO/'deploy/config/node_projects.json').read_text())
    result=[]
    for host, target in inventory['hosts'].items():
        for item in target['services']:
            name=item['name']
            project=next((p for p in projects if p['name']==name),None)
            if name.startswith('top-scores-') and name!='top-scores-web':
                project=next(p for p in projects if p['name']=='top-scores')
            definition=next((s for s in (project or {}).get('services',[]) if s.get('service_label')==item['unit']),project or {})
            directory=item['directory'].replace('~',HOSTS[host]['home'])
            logs=[str(Path(directory)/definition.get('log_file',name+'.log')),
                  str(Path(directory)/definition.get('error_log_file',name+'.error.log'))]
            pilot=name=='top-scores' or name.startswith('top-scores-')
            health='/healthcheck'
            if name=='train-loading-service': health='/health/ready'
            if name=='top-scores-bsd': health='/health'
            if name.endswith('-web') or name in ('goal-guesser','sky-no-limit-web'): health='/'
            row={'name':name,'host':host,'owner':'mini' if host=='sky' else 'sky',
                 'unit':item['unit'],'directory':directory,'logs':logs,
                 'healthUrl':f"http://127.0.0.1:{item['port']}{health}",
                 'publicUrl':item.get('public_url'),'runtimePort':item['runtime_port'],
                 'dependencies':[], 'autoActions':['restart','redeploy'] if pilot else [],
                 'approvalActions':['restart'], 'group':'top-scores-api' if pilot and name!='top-scores-web' else name}
            if name=='top-scores-web':
                row['dependencies']=['top-scores']
                row['dependencyProbes']={'top-scores':'http://127.0.0.1:3011/healthcheck'}
            if item.get('scope'): row['scope']=item['scope']
            if item.get('admin_helper'): row['adminHelper']=item['admin_helper']
            result.append(row)
    return result


def cached_keys():
    path=Path.home()/'.cache/server-tooling/bitwarden-env'
    values={}
    if path.exists():
        for token in shlex.split(path.read_text(),comments=True):
            if '=' in token:
                key,value=token.split('=',1)
                values[key]=value
    return values


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true',help='Provision host state and restricted SSH keys')
    args=parser.parse_args()
    registry=services()
    (SOURCE/'config').mkdir(exist_ok=True)
    (SOURCE/'config/services.json').write_text(json.dumps(registry,indent=2)+'\n')
    if not args.apply:
        print('Generated service registry. Use --apply to provision hosts.')
        return
    os.umask(0o077)
    cached=cached_keys()
    peer_token=secrets.token_urlsafe(36)
    openai=cached.get('OPENAI_API_KEY_KIDSPLORERS','')
    anthropic=cached.get('ANTHROPIC_API_KEY_KIDSPLORERS','')
    cloud=[{'kind':'openai','model':'gpt-4.1-mini','keyEnv':'OPENAI_API_KEY','inputPerMillion':0.4,
            'outputPerMillion':1.6,'timeoutMs':45000,'maxOutputTokens':1500},
           {'kind':'anthropic','model':'claude-haiku-4-5-20251001','keyEnv':'ANTHROPIC_API_KEY','inputPerMillion':1,
            'outputPerMillion':5,'timeoutMs':45000,'maxOutputTokens':1500}]
    cloud.reverse()
    public_keys={}
    host_keys={}
    for host,h in HOSTS.items():
        root=h['home']+'/.local/share/aiops'
        ssh(host, f"mkdir -p {root}/ssh {root}/runtime && chmod 700 {root} {root}/ssh && "
            f"test -f {root}/ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -f {root}/ssh/id_ed25519")
        public_keys[host]=ssh(host,f'cat {root}/ssh/id_ed25519.pub').strip()
        host_keys[host]=ssh(host,'cat /etc/ssh/ssh_host_ed25519_key.pub').strip()
        # Install only the restricted runner outside the source-sync directory.
        write(host,root+'/runner.py',(SOURCE/'runner.py').read_text(),0o700)
        write(host,root+'/runner.json',json.dumps({'cooldownSeconds':900,'services':[s for s in registry if s['host']==host]},indent=2))
        if host=='sky':
            ssh(host,f"test -x {root}/runtime/node || cp {h['node']} {root}/runtime/node")
        config={'host':host,'listen':h['ip'],'port':19444,'stateDir':root,
                'publicUrl':f"http://{h['dns']}:19444",'automatic':False,'budgetUsd':2,
                'peers':{other:f"http://{v['dns']}:19444" for other,v in HOSTS.items() if other!=host},
                'ssh':{other:{'destination':f"mwagstaff@{v['ip']}",'runner':v['home']+'/.local/share/aiops/runner.py'} for other,v in HOSTS.items()},
                'providers':([{'kind':'ollama','model':'qwen3.5:9b','inputPerMillion':0,'outputPerMillion':0,
                               'timeoutMs':120000,'maxOutputTokens':1500}]+cloud if host=='mini' else cloud)}
        # Preserve host-specific settings, especially queue IDs and model choices.
        existing=ssh(host,f'test ! -f {root}/config.json || cat {root}/config.json')
        if not existing:
            write(host,root+'/config.json',json.dumps(config,indent=2))
        existing_env=ssh(host,f'test ! -f {root}/secrets.env || cat {root}/secrets.env')
        values={}
        if existing_env:
            for token in shlex.split(existing_env,comments=True):
                if '=' in token:
                    k,v=token.split('=',1);values[k]=v
        values.setdefault('AIOPS_DASHBOARD_PASSWORD',secrets.token_urlsafe(30))
        values.setdefault('AIOPS_WEBHOOK_TOKEN',secrets.token_urlsafe(36))
        values['AIOPS_PEER_TOKEN']=peer_token
        if openai: values.setdefault('OPENAI_API_KEY',openai)
        if anthropic: values.setdefault('ANTHROPIC_API_KEY',anthropic)
        for key in ['PUSHOVER_USER_KEY','PUSHOVER_API_KEY_MONITORING']:
            values[key]=ssh(host,f'cat {h["home"]}/.local/share/server-tooling-monitoring/secrets/{key}').strip()
        # SMTP credential stays in process memory while being transferred.
        smtp=ssh('sky','sudo -n cat /home/mwagstaff/monitoring/secrets/plunk-smtp-password').strip()
        if smtp:
            values.update(SMTP_HOST='next-smtp.useplunk.com',SMTP_PORT='2587',SMTP_USER='plunk',SMTP_PASSWORD=smtp)
        write(host,root+'/secrets.env','\n'.join(k+'='+json.dumps(v) for k,v in values.items())+'\n')
        write(host,root+'/webhook-token',values['AIOPS_WEBHOOK_TOKEN'])
        print(f'{host}: private configuration, runtime and credentials provisioned; automatic recovery disabled')
    for host,h in HOSTS.items():
        other='sky' if host=='mini' else 'mini'
        root=h['home']+'/.local/share/aiops'
        write(host,root+'/ssh/known_hosts',HOSTS[other]['ip']+' '+host_keys[other]+'\n')
        forced=f'restrict,command="{h["python"]} {root}/runner.py" '+public_keys[other]
        code="""import pathlib,sys
p=pathlib.Path.home()/'.ssh/authorized_keys'
p.parent.mkdir(mode=0o700,exist_ok=True)
line=sys.stdin.read().strip()
old=p.read_text() if p.exists() else ''
if line not in old.splitlines():
    with p.open('a') as f: f.write(('\\n' if old and not old.endswith('\\n') else '')+line+'\\n')
p.chmod(0o600)
"""
        ssh(host,'python3 -c '+shlex.quote(code),forced)
        print(f'{host}: peer key restricted to the AIOps runner; host identity pinned')


if __name__=='__main__':
    main()
