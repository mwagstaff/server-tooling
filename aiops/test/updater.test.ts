import test from 'node:test';
import assert from 'node:assert/strict';
import {Store} from '../lib/store.ts';
import {Engine} from '../lib/engine.ts';
import {alertsFromWebhook} from '../lib/alerts.ts';
import {HealthMonitor} from '../lib/health.ts';
import {metrics} from '../lib/metrics.ts';
import type {Config} from '../lib/types.ts';
const service={name:'kidsplorers-events-worker',host:'mini',owner:'sky',autoActions:['update_ollama'],approvalActions:[]};
const config={host:'sky',services:[service],automatic:true,publicUrl:'http://sky',notification:{},ssh:{},providers:[],budgetUsd:1,staleAfterMs:86400000,alertmanagerUrl:'http://am'} as unknown as Config;
const checks={ollamaUpdateStateReadable:true,ollamaUpdateCheckFresh:true,ollamaUpdateHealthy:true,ollamaUpdateTimely:false,ollamaUpdateNotStuck:true};
function setup(t:any,change:any={}) {
 const store=new Store(':memory:');t.after(()=>store.db.close());
 const raw={labels:{alertname:'OllamaUpdateOverdue',host:'mini',service:service.name,component:'ollama-updater'},annotations:{summary:'Ollama updater maintenance overdue'},startsAt:new Date(Date.now()-1000).toISOString(),status:'firing'};
 const i=store.ingest(alertsFromWebhook({alerts:[raw]},config)[0]).incident;
 let update:any={checks:{...checks},phase:'idle',reviewRequired:false,pendingSince:Date.now()/1000-15*86400,...change},firing=true,requests=0;
 t.mock.method(globalThis,'fetch',async()=>Response.json(firing?[{...raw,status:{state:'active'}}]:[]));
 const run=async(_c:any,_s:any,operation:string,extra:any)=>{
  if(operation==='inspect')return {healthy:true,status:{active:true},health:{ok:true},logs:{},workerHealth:{checkedAt:new Date().toISOString(),checks:{dailyJobSucceeded:true},lastRun:{ok:28,failed:0},ollamaUpdate:update}};
  assert.equal(operation,'update_ollama');requests++;update.aiopsRequest={id:extra.actionId,status:'queued',expiresAt:Date.now()/1000+600,requestedAt:Date.now()/1000};return {ok:true};
 };
 const engine=new Engine(config,store,run as any,async()=>{throw new Error('Updater must not use model decisions');});
 return {store,i,engine,update,requests:()=>requests,clear:()=>{firing=false;}};
}
test('overdue patch queues a fixed updater action, waits quietly and verifies source resolution',async t=>{
 const {store,i,engine,update,requests,clear}=setup(t);
 await engine.investigate(i);
 assert.equal(store.get(i.id)!.status,'waiting_update');assert.equal(requests(),1);
 assert.equal(store.events(i.id).filter(e=>e.kind==='summary').length,0);
 await engine.investigateUpdater(store.get(i.id)!,service as any);assert.equal(requests(),1);
 update.aiopsRequest.status='succeeded';update.checks.ollamaUpdateTimely=true;
 await engine.investigateUpdater(store.get(i.id)!,service as any);assert.equal(store.get(i.id)!.status,'waiting_update');
 clear();await engine.investigateUpdater(store.get(i.id)!,service as any);
 assert.equal(store.get(i.id)!.status,'healthy');assert.equal(store.get(i.id)!.verification.workerHealthy,true);
 const summary=store.events(i.id).find(e=>e.kind==='summary')!.data;
 assert.match(summary.title,/Ollama updater/);assert.match(summary.text,/Kidsplorers impact: No failure detected/);
});
for(const change of [{reviewRequired:true},{checks:{...checks,ollamaUpdateHealthy:false}},{phase:'rollback'}])test(`unsafe updater state requires review ${JSON.stringify(change)}`,async t=>{
 const {store,i,engine,requests}=setup(t,change);await engine.investigate(i);
 assert.equal(requests(),0);assert.equal(store.get(i.id)!.status,'needs_review');
});
test('busy deferrals retry no sooner than 30 minutes and stop after three requests',async t=>{
 const {store,i,engine,update,requests}=setup(t);await engine.investigate(i);
 for(let n=1;n<=3;n++) {
  update.aiopsRequest.status='deferred';update.aiopsRequest.finishedAt=Date.now()/1000;
  await engine.investigateUpdater(store.get(i.id)!,service as any);assert.equal(requests(),n);
  update.aiopsRequest.finishedAt-=1801;
  await engine.investigateUpdater(store.get(i.id)!,service as any);assert.equal(requests(),Math.min(n+1,3));
 }
 assert.equal(store.get(i.id)!.status,'needs_review');
});
test('failed updater never replays and disabled automation never requests an update',async t=>{
 const {store,i,engine,update,requests}=setup(t);store.set('automatic',false);await engine.investigate(i);assert.equal(requests(),0);
 store.set('automatic',true);await engine.investigate(i);assert.equal(requests(),1);
 update.aiopsRequest.status='failed';await engine.investigateUpdater(store.get(i.id)!,service as any);
 assert.equal(requests(),1);assert.equal(store.get(i.id)!.status,'needs_review');
});
test('unknown source state never authorizes an update',async t=>{
 const {store,i,engine,requests}=setup(t);t.mock.method(globalThis,'fetch',async()=>{throw new Error('offline');});
 await engine.investigate(i);assert.equal(requests(),0);assert.equal(store.get(i.id)!.status,'needs_review');
});
test('maintenance metrics do not turn a healthy worker into an outage',()=>{
 const c={...config,host:'mini'},store=new Store(':memory:'),health=new HealthMonitor(c);
 try {
  health.reports=[{name:service.name,host:'mini',status:'healthy',checkedAt:new Date().toISOString(),checks:{dailyJobSucceeded:true},ollamaUpdate:{checks}}];
  const output=metrics(c,store,health);
  assert.match(output,/aiops_service_healthy\{service="kidsplorers-events-worker"\} 1/);
  assert.match(output,/aiops_ollama_update_overdue\{service="kidsplorers-events-worker"\} 1/);
  assert.match(output,/aiops_ollama_updater_healthy\{service="kidsplorers-events-worker"\} 1/);
 } finally {store.db.close();}
});
