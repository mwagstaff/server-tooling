import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Store} from '../lib/store.ts';
import {Engine} from '../lib/engine.ts';
import {alertsFromWebhook,alertFromEmail} from '../lib/alerts.ts';
import {relayApplication,receiveRelay} from '../lib/routing.ts';
import {selectRunbook,maintenanceFindings} from '../lib/runbooks.ts';
import {enqueueSummary} from '../lib/notifications.ts';
import {createApp,reconcileAlerts} from '../server.ts';
import type {Config} from '../lib/types.ts';
const config={host:'mini',services:[{name:'top-scores',host:'sky',owner:'mini',autoActions:['restart'],approvalActions:['restart']}],peers:{sky:'http://sky'},peerToken:'peer-secret',webhookToken:'webhook-secret',
 alertmanagerUrl:'http://am',prometheusUrl:'http://prom',publicUrl:'http://mini',notification:{},ssh:{},providers:[],budgetUsd:2,staleAfterMs:86400000} as unknown as Config;
const raw=()=>({labels:{alertname:'TopScoresEloImportFailed',host:'sky',service:'top-scores'},annotations:{summary:'Import failed',description:'HTTP 403. Last dataset update: '+new Date(Date.now()-7200000).toISOString()+'.'},
 startsAt:new Date(Date.now()-1000).toISOString(),endsAt:new Date(Date.now()+3600000).toISOString(),status:'firing'});
function incident(s:Store) {return s.ingest(alertsFromWebhook({alerts:[raw()]},config)[0]).incident;}

test('relay goes to the owning peer, canonicalizes labels and retains source expiry',async t=>{
 const source={...config,host:'sky',peers:{mini:'http://mini'}};
 const r=raw();r.labels.host='ubuntu-4gb-hel1-2';
 let calls:any[]=[];
 t.mock.method(globalThis,'fetch',async(url:any,options:any)=>{calls.push({url,body:JSON.parse(options.body),headers:options.headers});return Response.json({});});
 assert.equal(await relayApplication(source,r,alertsFromWebhook({alerts:[r]},source)[0]),true);
 assert.equal(calls[0].url,'http://mini/api/relay-alerts');
 assert.equal(calls[0].body.alerts[0].labels.host,'sky');
 await receiveRelay(config,calls[0].body);
 assert.equal(calls[1].url,'http://am/api/v2/alerts');
 assert.equal(calls[1].body[0].endsAt,r.endsAt);
 assert.equal(await relayApplication(config,r,alertsFromWebhook({alerts:[r]},config)[0]),false);
});
test('relay failures remain retryable and unknown or wrong-owner inputs cannot be injected',async t=>{
 t.mock.method(globalThis,'fetch',async()=>Response.json({}, {status:503}));
 const r=raw();const a=alertsFromWebhook({alerts:[r]},config)[0];
 await assert.rejects(relayApplication({...config,host:'sky',peers:{mini:'http://mini'}},r,a),/relay failed/);
 await assert.rejects(receiveRelay({...config,host:'sky'},{alerts:[r]}),/owned/);
 await assert.rejects(receiveRelay(config,{alerts:[{...r,labels:{...r.labels,service:'unknown'}}]}),/owned/);
 await assert.rejects(receiveRelay(config,{alerts:[{...r,endsAt:'bad'}]}),/expiry/);
});
test('relay endpoint requires peer credentials, not dashboard or webhook credentials',async t=>{
 const s=new Store(':memory:');const server=createApp(config,s,new Engine(config,s));
 await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
 t.after(()=>{server.close();s.db.close();});
 for(const token of ['',config.webhookToken]) {
  const r=await fetch(`http://127.0.0.1:${(server.address() as any).port}/api/relay-alerts`,{method:'POST',headers:{Authorization:'Bearer '+token},body:JSON.stringify({alerts:[raw()]})});
  assert.equal(r.status,401);
 }
});
test('reconciliation relays misdirected applications without creating a second local incident',async t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());let relays=0;
 t.mock.method(globalThis,'fetch',async(url:any)=>{
  if(String(url).includes('/api/relay-alerts')){relays++;return Response.json({});}
  return Response.json([{...raw(),status:{state:'active'}}]);
 });
 await reconcileAlerts({...config,host:'sky',peers:{mini:'http://mini'}},s);
 assert.equal(relays,1);assert.equal(s.list().length,0);
});
test('two full snapshots close a missing source and deliver resolution once after maintenance',async t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());const i=incident(s);enqueueSummary(config,s,i);
 s.set('maintenance:windows',[{host:'sky',services:['top-scores'],endsAt:Date.now()+60000}]);
 t.mock.method(globalThis,'fetch',async(url:any)=>{assert.match(String(url),/silenced=true&inhibited=true/);return Response.json([]);});
 await reconcileAlerts(config,s);assert.equal(s.get(i.id)!.resolvedAt,undefined);
 s.set('source:absent:'+i.id,Date.now()-61000);
 await reconcileAlerts(config,s);assert.ok(s.get(i.id)!.resolvedAt);
 assert.equal(s.events(i.id).filter(e=>e.kind==='summary').length,1);
 s.set('maintenance:windows',[]);
 await reconcileAlerts(config,s);await reconcileAlerts(config,s);
 assert.equal(s.events(i.id).filter(e=>e.kind==='summary').length,2);
 assert.match(s.events(i.id).filter(e=>e.kind==='summary')[1].data.title,/SOURCE CLEARED/);
});
test('suppressed or unprocessed sources prevent false resolution; failed snapshots cannot clear',async t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());const r=raw();const i=s.ingest(alertsFromWebhook({alerts:[r]},config)[0]).incident;
 let state='suppressed';
 t.mock.method(globalThis,'fetch',async()=>state==='failure'?Response.json({}, {status:503}):Response.json([{...r,status:{state}}]));
 for(state of ['suppressed','unprocessed','failure']) {
  s.set('source:absent:'+i.id,Date.now()-61000);
  if(state==='failure')await assert.rejects(reconcileAlerts(config,s));else await reconcileAlerts(config,s);
  assert.equal(s.get(i.id)!.resolvedAt,undefined);
 }
});
test('invalid snapshot entry cannot falsely close an incident',async t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());const i=incident(s);s.set('source:absent:'+i.id,Date.now()-61000);
 t.mock.method(globalThis,'fetch',async()=>Response.json([{...raw(),startsAt:'bad',status:{state:'active'}}]));
 await reconcileAlerts(config,s);assert.equal(s.get(i.id)!.resolvedAt,undefined);
});
test('upstream 403 follows recorded read-only runbook, reports age and never calls model or recovery',async t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());const i=incident(s);
 const inspect=async(_c:any,_s:any,action:any)=>{assert.equal(action,'inspect');return {healthy:true,status:{active:true},logs:{}};};
 t.mock.method(globalThis,'fetch',async()=>Response.json([{...raw(),startsAt:i.alert.startsAt,status:{state:'active'}}]));
 const model=async()=>{throw new Error('must not invoke model');};
 await new Engine(config,s,inspect as any,model as any).investigate(i);
 const saved=s.get(i.id)!;
 assert.deepEqual(saved.runbook,{id:'upstream-import',version:1});
 assert.equal(saved.action,'none');assert.equal(saved.spent,0);assert.equal(saved.evidence.reportedDatasetAgeHours,2);
 assert.equal(saved.status,'needs_review');assert.match(saved.diagnosis,/Retain the last validated dataset/);
 assert.equal(s.events(i.id).filter(e=>e.kind==='runbook').length,1);
});
test('weekly report maps to maintenance and preserves uncertainty about historical warnings',async()=>{
 const a=alertFromEmail({id:'report',subject:'[REVIEW] sky weekly upgrade report',text:'Failed system services. Remaining upgrades. Tunnel shutdown timeout. old binaries',receivedAt:new Date().toISOString()},config);
 assert.equal(a.service,'maintenance');assert.equal(a.name,'WeeklyUpgradeReview');assert.equal(a.host,'sky');
 const s=new Store(':memory:');const i=s.ingest(a).incident;
 await new Engine(config,s).investigate(i);
 assert.equal(s.get(i.id)!.verification.healthy,null);assert.equal(s.get(i.id)!.action,'none');
 assert.match(s.get(i.id)!.diagnosis,/phased/);assert.equal(selectRunbook(i).id,'upgrade-review');s.db.close();
 assert.match(maintenanceFindings('active session reboot deferred').join(' '),/not permission to force reboot/);
});
test('incident correlation links same-host intake symptoms across peers without merging identity',async t=>{
 const s=new Store(':memory:');t.after(()=>s.db.close());const a=alertsFromWebhook({alerts:[{...raw(),labels:{host:'sky',service:'aiops',alertname:'AIOpsReconciliationStalled'}}]},config)[0];
 const i=s.ingest(a).incident;
 t.mock.method(globalThis,'fetch',async(url:any)=>{
  if(String(url).includes('related-incidents'))return Response.json({incidents:[{id:'related',host:'sky',name:'MonitoringNotificationFailures',startsAt:i.alert.startsAt,url:'http://sky/?incident=related'},{id:'unrelated',host:'mini',name:'MonitoringNotificationFailures',startsAt:i.alert.startsAt,url:'http://sky/?incident=unrelated'}]});
  if(String(url).includes('/api/v2/alerts'))return Response.json([]);
  return Response.json({status:'success',data:{result:[]}});
 });
 await new Engine(config,s).investigate(i);
 assert.deepEqual(s.get(i.id)!.related?.map(x=>x.id),['related']);assert.equal(s.list().length,1);
 assert.match(s.events(i.id).find(e=>e.kind==='summary')!.data.text,/Possible shared cause/);
});

test('existing source-cleared summaries survive deduplication migration without resending',()=>{
 const s=new Store(':memory:');const i=incident(s);i.resolvedAt=new Date().toISOString();s.put(i);
 s.event(i.id,'summary',{title:'[AIOps SOURCE CLEARED] old summary'});
 enqueueSummary(config,s,i);
 assert.equal(s.events(i.id).filter(e=>e.kind==='summary').length,1);s.db.close();
});
test('relay preserves explicit source resolution',async t=>{
 const r={...raw(),status:'resolved',endsAt:new Date().toISOString()};let payload:any;
 t.mock.method(globalThis,'fetch',async(_u:any,o:any)=>{payload=JSON.parse(o.body);return Response.json({});});
 await receiveRelay(config,{alerts:[r]});
 assert.ok(Date.parse(payload[0].endsAt)<=Date.now());assert.equal(payload[0].startsAt,r.startsAt);
});

test('zero-time firing expiry is obtained from the authoritative source snapshot',async t=>{
 const r=raw();const a=alertsFromWebhook({alerts:[r]},config)[0];let forwarded:any;
 t.mock.method(globalThis,'fetch',async(url:any,o:any)=>{
  if(String(url).endsWith('/api/v2/alerts'))return Response.json([r]);
  forwarded=JSON.parse(o.body);return Response.json({});
 });
 await relayApplication({...config,host:'sky',peers:{mini:'http://mini'}},{...r,endsAt:'0001-01-01T00:00:00Z'},a);
 assert.equal(forwarded.alerts[0].endsAt,r.endsAt);
});

test('webhook returns retryable 503 when the owning responder cannot accept a relay',async t=>{
 const source={...config,host:'sky',peers:{mini:'http://mini'}};const s=new Store(':memory:');
 const server=createApp(source,s,new Engine(source,s));await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
 t.after(()=>{server.close();s.db.close();});
 const client=globalThis.fetch;
 t.mock.method(globalThis,'fetch',async()=>Response.json({}, {status:503}));
 const r=await client(`http://127.0.0.1:${(server.address() as any).port}/webhooks/alertmanager`,{method:'POST',headers:{Authorization:'Bearer '+source.webhookToken,'Content-Type':'application/json'},body:JSON.stringify({alerts:[raw()]})});
 assert.equal(r.status,503);assert.equal(s.list().length,0);
});
