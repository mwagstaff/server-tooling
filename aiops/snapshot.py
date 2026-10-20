#!/usr/bin/env python3
"""Capture verified deployed code for bounded repair, without copying secrets/data."""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
from provision import ssh, HOSTS

SOURCE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('runner',SOURCE/'runner.py')
runner=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,default=Path.home()/'dev/top-scores')
    parser.add_argument('--group',choices=['top-scores-api','top-scores-web'],required=True)
    args=parser.parse_args()
    prefix='api' if args.group=='top-scores-api' else 'web'
    output=subprocess.check_output(['git','-C',str(args.repo),'ls-files','-z',prefix])
    paths=[]
    for raw in output.decode().split('\0'):
        if not raw: continue
        relative=str(Path(raw).relative_to(prefix))
        if 'test' in Path(relative).parts or '.test.' in relative or relative in ('package.json','package-lock.json'): continue
        try: runner.safe_relative(relative)
        except ValueError: continue
        paths.append(relative)
    code="""import pathlib,json,sys,hashlib,shutil,datetime,urllib.request,subprocess,uuid
root=pathlib.Path.home()/'.local/share/aiops'
request=json.load(sys.stdin)
config=json.loads((root/'runner.json').read_text())
group=request['group']
services=[s for s in config['services'] if s['group']==group]
if not services: raise RuntimeError('Unknown release group')
for s in services:
    subprocess.run(['systemctl','--user','is-active','--quiet',s['unit']+'.service'],check=True)
    with urllib.request.urlopen(s['healthUrl'],timeout=8) as r:
        if r.status!=200: raise RuntimeError('Health check failed')
directory=pathlib.Path(services[0]['directory']).resolve()
destination=root/'releases'/group
candidate=root/'releases'/('candidate-'+uuid.uuid4().hex)
(candidate/'files').mkdir(parents=True,mode=0o700)
manifest={'directory':str(directory),'created':datetime.datetime.now(datetime.timezone.utc).isoformat(),'files':{},'dependencies':{}}
total=0
for name in request['files']:
    p=directory/name
    if not p.is_file() or p.is_symlink() or directory not in p.resolve().parents: continue
    total+=p.stat().st_size
    if total>100*1024*1024: raise RuntimeError('Release code exceeds 100 MiB')
    data=p.read_bytes()
    target=candidate/'files'/name
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(data)
    manifest['files'][name]=hashlib.sha256(data).hexdigest()
for name in ['package.json','package-lock.json']:
    if (directory/name).is_file(): manifest['dependencies'][name]=hashlib.sha256((directory/name).read_bytes()).hexdigest()
if not manifest['files']: raise RuntimeError('No release files')
(candidate/'manifest.json').write_text(json.dumps(manifest,indent=2))
if destination.exists():
    destination.rename(root/'releases'/(group+'-previous-'+uuid.uuid4().hex))
candidate.rename(destination)
print(json.dumps({'group':group,'files':len(manifest['files']),'bytes':total,'health':'verified'}))
"""
    print(ssh('sky','python3 -c '+shlex.quote(code),json.dumps({'group':args.group,'files':paths})).strip())


if __name__=='__main__':
    main()
