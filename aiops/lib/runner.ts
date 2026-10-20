import {spawn} from 'node:child_process';
import type {Config, Service} from './types.ts';
import {redact} from './security.ts';

export function runTarget(config: Config, service: Service | {host:string;name:string}, operation: string, extra: object = {}): Promise<any> {
  const target = config.ssh[service.host];
  if (!target) throw new Error('Host is not registered');
  const local = service.host === config.host;
  const command = local ? 'python3' : 'ssh';
  // Remote identity has a forced command: client cannot select a shell command.
  const args = local ? [target.runner] : ['-i',`${config.stateDir}/ssh/id_ed25519`,
    '-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
    '-o',`UserKnownHostsFile=${config.stateDir}/ssh/known_hosts`,
    '-o','ConnectTimeout=8','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=2',
    target.destination];
  return new Promise((resolve,reject) => {
    const child = spawn(command,args,{stdio:['pipe','pipe','pipe']});
    let out = '', error = '', exceeded = false;
    const timer = setTimeout(() => child.kill('SIGKILL'), operation==='health_all'?60000:150000);
    child.stdout.on('data', data => { out += data; if(out.length > 128000) {exceeded=true;child.kill('SIGKILL');} });
    child.stderr.on('data', data => { error = (error + data).slice(-2000); });
    child.on('error',e => {clearTimeout(timer);reject(e);});
    child.on('close', code => {
      clearTimeout(timer);
      if (code !== 0 || exceeded) return reject(new Error(`Target runner failed (${code}): ${redact(error)}`));
      try { resolve(JSON.parse(out)); } catch { reject(new Error('Invalid target runner response')); }
    });
    child.stdin.on('error',()=>{});
    child.stdin.end(JSON.stringify({service:service.name,operation,...extra}));
  });
}
