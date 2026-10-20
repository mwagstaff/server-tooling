// Deployment entry works with the system Node 20 wrapper on Sky. The private
// Node 24+ runtime is provisioned separately; no production app runtime is changed.
import {homedir} from 'node:os';
import {spawn} from 'node:child_process';
if (Number(process.versions.node.split('.')[0]) < 24) {
  const child=spawn(`${homedir()}/.local/share/aiops/runtime/node`,
    [new URL('./server.ts',import.meta.url).pathname],{stdio:'inherit',env:process.env});
  for(const signal of ['SIGTERM','SIGINT']) process.on(signal,()=>child.kill(signal));
  child.on('error',()=>{console.error('Provision the AIOps Node 24+ runtime first.');process.exit(1);});
  child.on('exit',code=>process.exit(code ?? 1));
} else {await import('./server.ts');}
