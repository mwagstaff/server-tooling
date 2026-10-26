import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {Store} from '../lib/store.ts';
import {Engine} from '../lib/engine.ts';
import {alertsFromWebhook} from '../lib/alerts.ts';
import {inspectInfrastructure,infrastructureOwner,infrastructureNames} from '../lib/infrastructure.ts';
import type {Alert,Config} from '../lib/types.ts';
const config={host:'mini',services:[],ssh:{},prometheusUrl:'http://metrics',alertmanagerUrl:'http://alerts',publicUrl:'http://mini:19444',
 staleAfterMs:86400000,budgetUsd:2,notification:{},peers:{}} as unknown as Config;
const alert:Alert={source:'alertmanager',key:'infra',host:'mini',service:'alertmanager',name:'MonitoringNotificationFailures',summary:'Delivery failure',status:'firing',
 startsAt:new Date(Date.now()-600000).toISOString(),receivedAt:new Date().toISOString(),labels:{host:'mini',service:'alertmanager',integration:'webhook',reason:'other'}};
const sample=(value:number,metric={})=>({metric,value:[Date.now()/1000,String(value)]});
function mock(t:any,missing=false,successfulIntegration='webhook') {
 t.mock.method(globalThis,'fetch',async(input:any)=>{
  const u=new URL(input);if(u.host==='alerts')return Response.json([]);
  const q=u.searchParams.get('query')!;assert.match(q,/host="mini"/);
  let result:any[]=[];
  if(!missing) {
   if(q.startsWith('up'))result=[sample(1)];
   else if(q.includes('failed_total'))result=[sample(u.searchParams.has('time')?1:0,{integration:'webhook',reason:'other'})];
   else result=[sample(4,{integration:successfulIntegration})];
  }
  return Response.json({status:'success',data:{result}});
 });
}
test('notification investigation shows recovered webhook failure without executing commands',async t=>{
 mock(t);const s=new Store(':memory:');t.after(()=>s.db.close());const i=s.ingest(alert).incident;
 const forbidden=async()=>{throw new Error('no commands or model');};
 await new Engine(config,s,forbidden as any,forbidden as any).investigate(i);
 const result=s.get(i.id)!;assert.equal(result.status,'healthy');assert.equal(result.verification.alertFiring,false);
 assert.match(result.diagnosis,/integration=webhook reason=other: 1.000/);assert.match(result.diagnosis,/delivery has resumed/);
 const text=s.events(i.id).find(e=>e.kind==='summary')!.data.text;
 assert.match(text,/monitoring-monitor/);assert.doesNotMatch(text,/Last logging|combined 5xx|var-service=alertmanager&.*monitoring-logs/);
 assert.equal(result.attempts,0);
});
test('success in a different channel cannot verify recovery',async t=>{
 mock(t,false,'pushover');const s=new Store(':memory:');t.after(()=>s.db.close());
 const result=await inspectInfrastructure(config,s.ingest(alert).incident);assert.equal(result.healthy,false);
 assert.match(result.diagnosis,/not yet verified/);
});
test('missing notification telemetry remains unknown',async t=>{
 mock(t,true);const s=new Store(':memory:');t.after(()=>s.db.close());
 assert.equal((await inspectInfrastructure(config,s.ingest(alert).incident)).healthy,undefined);
});
test('monitor-local and peer-observed infrastructure use the correct responder',()=>{
 assert.equal(infrastructureOwner({host:'mini',alert:{name:'MonitoringRuleFailures'}} as any),'mini');
 assert.equal(infrastructureOwner({host:'mini',alert:{name:'HostCpuPressure'}} as any),'sky');
 assert.equal(infrastructureOwner({host:'mini',alert:{name:'DnsDown'}} as any),'mini');
});
test('notification reasons/channels and mountpoints are distinct; an old identity migrates without duplicating its incident',()=>{
 const raw:{alerts:{labels:Record<string,string>;startsAt:string;status:string}[]}={alerts:[{labels:{...alert.labels,alertname:alert.name},startsAt:alert.startsAt,status:'firing'}]};
 const a=alertsFromWebhook(raw,config)[0];raw.alerts[0].labels.integration='pushover';const b=alertsFromWebhook(raw,config)[0];assert.notEqual(a.key,b.key);
 const s=new Store(':memory:');try {
  const old=s.ingest({...a,key:'legacy'}).incident;s.ingest(b);
  const updated=s.ingest({...a,status:'resolved'});assert.equal(updated.incident.id,old.id);assert.ok(updated.incident.resolvedAt);assert.equal(s.list().length,2);
 }finally{s.db.close();}
});
test('source status matches the exact integration, not another active notification failure',async t=>{
 t.mock.method(globalThis,'fetch',async()=>Response.json([{labels:{...alert.labels,integration:'pushover',alertname:alert.name},startsAt:alert.startsAt,status:{state:'active'}}]));
 const s=new Store(':memory:');try{assert.equal(await new Engine(config,s).alertStillFiring(s.ingest(alert).incident),false);}finally{s.db.close();}
});
test('every generated infrastructure alert has an investigation or is an intentional canary',()=>{
 const names=JSON.parse(execFileSync('python3',['-c',`import sys,json
sys.path.insert(0,'../monitoring/platform')
from config import make_rules
print(json.dumps(sorted({r['alert'] for monitor,target in [('mini','sky'),('sky','mini')] for g in make_rules([],target,aiops=True,monitor=monitor,logging=True)['groups'] for r in g['rules'] if 'alert' in r})))`],{encoding:'utf8'}));
 const application=['RuntimeUnavailable','AppMetricsUnavailable','PublicEndpointUnavailable','PublicProbeUnavailable','HeapPressure','HeapCritical','RestartLoop','HttpErrors','HttpAbortedRequests','CertificateExpiring','ServiceHealthFailing','ServiceHealthStale','AppCheckFailing','AppCheckFailingLong'];
 const logging=['LogEntriesDropped','LogCollectorUnavailable','LogPipelineStalled','LogStorageSpaceLow','LogTelemetryMissing'];
 const covered=new Set([...infrastructureNames,...application,...logging,'MonitoringWatchdog','AIOpsPipelineCanary']);
 assert.deepEqual(names.filter((n:string)=>!covered.has(n)),[]);
});


test('all monitored application targets have an AIOps registration',()=>{
 const missing=JSON.parse(execFileSync('python3',['-c',`import json
inventory=json.load(open('../monitoring/platform/inventory.json'))['hosts']
registry={(s['host'],s['name']) for s in json.load(open('config/services.json'))}
print(json.dumps([(host,s['name']) for host,info in inventory.items() for s in info['services'] if (host,s['name']) not in registry]))`],{encoding:'utf8'}));
 assert.deepEqual(missing,[]);
});
