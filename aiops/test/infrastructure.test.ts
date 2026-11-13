import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {enqueueSummary} from '../lib/notifications.ts';
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

const publicAlert:Alert={...alert,key:'public',host:'sky',service:'unknown',name:'SharedPublicOutage',
 labels:{host:'sky',alertname:'SharedPublicOutage'}};
const publicRows=[sample(1,{service:'a',job:'public-a',instance:'https://a'}),
 sample(1,{service:'b',job:'public-b',instance:'https://b'})];
function publicMock(t:any,options:{missing?:boolean;stale?:boolean;failed?:boolean;active?:boolean;down?:boolean}={}) {
 t.mock.method(globalThis,'fetch',async(input:any)=>{
  const u=new URL(input);
  if(u.host==='alerts')return Response.json(options.active?[{labels:publicAlert.labels,startsAt:publicAlert.startsAt,status:{state:'active'}}]:[]);
  const q=u.searchParams.get('query')!;
  let rows=publicRows.map(r=>({...r,value:[...r.value]}));
  if(q.startsWith('timestamp'))rows=rows.map(r=>({...r,value:[Date.now()/1000,String(Date.now()/1000-(options.stale?120:2))]}));
  else if(q.startsWith('up') && options.down)rows[0].value[1]='0';
  else if(q.startsWith('probe_success') && !u.searchParams.has('time')) {
    if(options.missing)rows.pop();
    if(options.failed)rows[0].value[1]='0';
  }
  return Response.json({status:'success',data:{result:rows}});
 });
}
test('shared outage closes only with fresh complete probes and cleared source, without commands/models',async t=>{
 publicMock(t);const s=new Store(':memory:');t.after(()=>s.db.close());
 const i=s.ingest(publicAlert).incident;const forbidden=async()=>{throw Error('forbidden');};
 await new Engine(config,s,forbidden as any,forbidden as any).investigate(i);
 const result=s.get(i.id)!;assert.equal(result.status,'healthy');assert.equal(result.runbook?.id,'shared-public-outage');
 assert.equal(result.attempts,0);assert.equal(result.spent,0);
});
for(const [name,options,expected] of [
 ['missing',{missing:true},undefined],['stale',{stale:true},undefined],
 ['collector down',{down:true},undefined],['failed',{failed:true},false]
] as const)test('shared outage does not close with '+name+' probes',async t=>{
 publicMock(t,options);const s=new Store(':memory:');t.after(()=>s.db.close());
 const i=s.ingest(publicAlert).incident;
 await new Engine(config,s).investigate(i);
 assert.equal(s.get(i.id)!.status,'needs_review');assert.equal(s.get(i.id)!.verification.healthy,expected);
});
test('shared outage rechecks after delayed source resolution and closes once',async t=>{
 const options={active:true};publicMock(t,options);
 const s=new Store(':memory:');t.after(()=>s.db.close());const i=s.ingest(publicAlert).incident;
 const forbidden=async()=>{throw Error('forbidden');};const engine=new Engine(config,s,forbidden as any,forbidden as any);
 await engine.investigate(i);assert.equal(s.get(i.id)!.status,'needs_review');
 options.active=false;s.ingest({...publicAlert,status:'resolved',receivedAt:new Date().toISOString()});
 enqueueSummary(config,s,s.get(i.id)!);
 await engine.tick();assert.equal(s.get(i.id)!.status,'healthy');
 assert.match(s.events(i.id).filter(e=>e.kind==='summary').at(-1)!.data.title,/AIOps RESOLVED/);
 const count=s.events(i.id).filter(e=>e.kind==='summary').length;
 await engine.tick();assert.equal(s.events(i.id).filter(e=>e.kind==='summary').length,count);
});
test('shared outage rechecks are bounded and respect pause and maintenance',async t=>{
 publicMock(t,{active:true});const s=new Store(':memory:');t.after(()=>s.db.close());
 const i=s.ingest(publicAlert).incident;const engine=new Engine(config,s);
 await engine.investigate(i);s.set('paused',true);await engine.tick();
 assert.equal(s.events(i.id).filter(e=>e.kind==='recovery_check').length,0);
 s.set('paused',false);
 s.set('maintenance:windows',[{host:'sky',services:[],endsAt:Date.now()+60000}]);await engine.tick();
 assert.equal(s.events(i.id).filter(e=>e.kind==='recovery_check').length,0);
 s.set('maintenance:windows',[]);await engine.tick();await engine.tick();
 assert.equal(s.events(i.id).filter(e=>e.kind==='recovery_check').length,1);
 assert.equal(s.get(i.id)!.status,'needs_review');
});

for(const [workflow,verification,sourceResolved,expected] of [
 ['healthy',{healthy:true,alertFiring:false},true,'RESOLVED'],
 ['needs_review',{alertFiring:false},true,'RESOLVED'],
 ['needs_review',{healthy:false,alertFiring:false},true,'ACTION REQUIRED'],
 ['healthy',{healthy:true,alertFiring:true},false,'ACTION REQUIRED'],
 ['needs_review',{alertFiring:null},false,'ACTION REQUIRED'],
 ['needs_approval',{healthy:false,alertFiring:true},false,'APPROVAL NEEDED']
] as const)test('notification title communicates action: '+workflow+' '+JSON.stringify(verification),t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());
 const original=s.ingest(publicAlert).incident;
 const updated={...original,status:workflow,verification,...(sourceResolved?{resolvedAt:new Date().toISOString()}:{})};
 s.put(updated);
 const cfg={...config,notification:{smtpHost:'smtp',emailTo:'test@example.test',pushoverToken:'test',pushoverUser:'test'}};
 enqueueSummary(cfg,s,original);
 const rows=s.db.prepare('SELECT data FROM notifications').all().map(r=>JSON.parse(r.data as string));
 assert.equal(rows.length,2);assert.equal(rows[0].title,rows[1].title);
 assert.ok(rows[0].title.startsWith('[AIOps '+expected+']'));
 assert.match(rows[0].title,/\] (Resolved|Action required|Approval needed):/);
 assert.doesNotMatch(rows[0].text,/SOURCE CLEARED|source alert cleared/);
});
