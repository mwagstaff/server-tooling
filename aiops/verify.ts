import {loadConfig} from './lib/config.ts';
import {Store} from './lib/store.ts';
import {runTarget} from './lib/runner.ts';
import {diagnose} from './lib/providers.ts';
import {randomUUID} from 'node:crypto';

const config=loadConfig();
let failed=false;
if(process.argv.includes('--models')) {
  for(const p of config.providers) {
    const store=new Store(':memory:');
    const incident=store.ingest({source:'selftest',key:randomUUID(),host:'sky',service:'fixture',
      name:'SyntheticProcessStopped',summary:'Synthetic test only: disposable process stopped.',
      status:'firing',startsAt:new Date().toISOString(),receivedAt:new Date().toISOString(),labels:{}}).incident;
    const decision=await diagnose({...config,providers:[p]},store,incident,{
      synthetic:true,status:{active:false,state:'inactive'},health:{ok:false},healthy:false,
      dependencies:{api:{ok:true}},logs:'Clean shutdown. No disk, memory or dependency errors.',
      permittedProcedure:'Restart the disposable service. It has no data or side effects.'
    },['restart']);
    const ok=store.events(incident.id).some(e=>e.kind==='decision');
    console.log(JSON.stringify({provider:p.kind,model:p.model,ok,action:decision.action,
      costUsd:incident.spent,reason:ok?undefined:decision.diagnosis,
      failures:ok?undefined:store.events(incident.id).filter(e=>e.kind==='provider_failed').map(e=>e.data)}));
    if(!ok) failed=true;
    store.db.close();
  }
} else {
  for(const host of Object.keys(config.ssh)) {
    try {
      const result=await runTarget(config,{name:'__host__',host},'inspect');
      const ok=Boolean(result.host);
      console.log(JSON.stringify({host,runnerReachable:ok}));
      if(!ok)failed=true;
    } catch {console.log(JSON.stringify({host,runnerReachable:false}));failed=true;}
  }
  for(const s of config.services.filter(s=>s.owner===config.host && s.name.startsWith('top-scores'))) {
    const result=await runTarget(config,s,'inspect');
    console.log(JSON.stringify({service:s.name,healthy:result.healthy,releaseAvailable:result.releaseAvailable}));
    if(!result.healthy)failed=true;
  }
}
process.exitCode=failed?1:0;
