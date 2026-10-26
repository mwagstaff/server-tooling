import {test} from 'node:test';
import assert from 'node:assert/strict';
import {inspectLogging} from '../lib/logging.ts';
import {Engine} from '../lib/engine.ts';
import {Store} from '../lib/store.ts';
import type {Config,Alert} from '../lib/types.ts';
const config={host:'mini',services:[],ssh:{},prometheusUrl:'http://metrics',alertmanagerUrl:'http://alerts',publicUrl:'http://mini:19444',
  staleAfterMs:86400000,budgetUsd:2,notification:{},peers:{}} as unknown as Config;
const alert:Alert={source:'alertmanager',key:'logging-test',host:'sky',service:'logging',name:'LogEntriesDropped',summary:'Logs dropped',status:'firing',
  startsAt:new Date(Date.now()-600000).toISOString(),receivedAt:new Date().toISOString(),labels:{host:'sky',service:'logging'}};
const sample=(value:number,metric={})=>({metric,value:[Date.now()/1000,String(value)]});
function fakeFetch(t:any,missing=false) {
  t.mock.method(globalThis,'fetch',async (input:any)=>{
    const u=new URL(input);
    if(u.host==='alerts') return Response.json([]);
    const q=u.searchParams.get('query')!;
    assert.match(q,/host="sky"/);
    let result:any[]=[];
    if(!missing) {
      if(q.startsWith('up')) result=[sample(1,{job:'alloy'}),sample(1,{job:'logs-health'})];
      else if(q.startsWith('time'))result=[sample(35)];
      else if(q.startsWith('logging_disk'))result=[sample(20*1073741824)];
      else result=[sample(u.searchParams.has('time')?147:0,{reason:'ratelimit_drop_stage'})];
    }
    return Response.json({status:'success',data:{result}});
  });
}
test('logging incident retains historical drop cause, verifies current health and never runs recovery or a model',async t=>{
  fakeFetch(t);const s=new Store(':memory:');t.after(()=>s.db.close());
  const i=s.ingest(alert).incident;
  const forbidden=async()=>{throw new Error('must not run');};
  await new Engine(config,s,forbidden as any,forbidden as any).investigate(i);
  const result=s.get(i.id)!;
  assert.equal(result.status,'healthy');assert.equal(result.verification.alertFiring,false);
  assert.match(result.diagnosis,/147/);assert.match(result.diagnosis,/rate limiter/);
  assert.equal(result.attempts,0);assert.equal(result.spent,0);
  const text=s.events(i.id).find(e=>e.kind==='summary')!.data.text;
  assert.match(text,/SOURCE CLEARED/);assert.match(text,/canary age 35s/);
  assert.match(text,/monitoring-logging/);assert.match(text,/var-service=.%2A/);
  assert.doesNotMatch(text,/combined 5xx|No unambiguous/);
});
test('missing logging evidence stays unknown, including an empty successful query',async t=>{
  fakeFetch(t,true);const s=new Store(':memory:');t.after(()=>s.db.close());
  const i=s.ingest(alert).incident;await new Engine(config,s).investigate(i);
  assert.equal(s.get(i.id)!.status,'needs_review');assert.equal(s.get(i.id)!.verification.healthy,undefined);
  assert.match(s.get(i.id)!.evidence.logging.summary,/unknown/);
});
test('logging investigation rejects the wrong owning responder without querying',async t=>{
  t.mock.method(globalThis,'fetch',async()=>{throw new Error('must not query');});
  const s=new Store(':memory:');t.after(()=>s.db.close());const i=s.ingest(alert).incident;
  await new Engine({...config,host:'sky'},s).investigate(i);
  assert.equal(s.get(i.id)!.status,'other_host');assert.equal(i.evidence,undefined);
});
test('all logging alert types produce specific next steps and measurements',async t=>{
  fakeFetch(t);const s=new Store(':memory:');t.after(()=>s.db.close());
  for(const [name,expected] of [['LogCollectorUnavailable','scrape checks'],['LogPipelineStalled','35 seconds'],['LogStorageSpaceLow','20.0 GiB']]) {
    const i=s.ingest({...alert,key:name,name}).incident;
    const evidence=await inspectLogging(config,i);assert.match(evidence.diagnosis,new RegExp(expected));
    assert.ok(evidence.nextStep.length>30);
  }
});
