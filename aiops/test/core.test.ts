import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {Store} from '../lib/store.ts';
import {Engine} from '../lib/engine.ts';
import {alertsFromWebhook,alertFromEmail} from '../lib/alerts.ts';
import {parseDecision,reserveCost,diagnose} from '../lib/providers.ts';
import {redact} from '../lib/security.ts';
import {createApp,pollQueue,reconcileAlerts} from '../server.ts';
import type {Config,Alert,Service} from '../lib/types.ts';

const service:Service={name:'top-scores',host:'sky',owner:'mini',unit:'test',directory:'/tmp',logs:[],
  healthUrl:'http://127.0.0.1:1',dependencies:[],autoActions:['restart'],approvalActions:['restart','redeploy'],group:'top-scores'};
const config:Config={host:'mini',listen:'127.0.0.1',port:0,stateDir:'/tmp/aiops-test',
  publicUrl:'http://localhost',dashboardPassword:'a'.repeat(32),webhookToken:'b'.repeat(32),
  peers:{},ssh:{},services:[service],providers:[],budgetUsd:2,automatic:true,cooldownSeconds:900,
  maxActions:2,alertmanagerUrl:'http://127.0.0.1:1',prometheusUrl:'http://127.0.0.1:1',
  verifyDelayMs:1,staleAfterMs:86400000,notification:{}};
const makeAlert=(overrides:Partial<Alert>={}):Alert=>({source:'email',key:Math.random().toString(),host:'sky',service:'top-scores',
  name:'TestFailure',summary:'Service unavailable',status:'firing',startsAt:new Date().toISOString(),
  labels:{},receivedAt:new Date().toISOString(),...overrides});
const webhook=()=>({alerts:[{labels:{host:'sky',service:'top-scores',alertname:'RuntimeUnavailable'},startsAt:new Date().toISOString(),status:'firing'}]});
const decision=async()=>({diagnosis:'Process is stopped.',action:'restart' as const,reason:'Restart registered service.',confidence:'high' as const});
const unhealthy={healthy:false,status:{active:false},health:{ok:false},logs:{},dependencies:{},releaseAvailable:false};

test('webhook maps registered service and ignores watchdog',()=>{
  const b=webhook();b.alerts.push({...b.alerts[0],labels:{...b.alerts[0].labels,alertname:'MonitoringWatchdog'}});
  assert.equal(alertsFromWebhook(b,config).length,1);
});
test('rejects service/host mismatch and invalid start timestamps',()=>{
  const b=webhook();b.alerts[0].labels.host='mini';
  assert.throws(()=>alertsFromWebhook(b,config));
  b.alerts[0].labels.host='sky';b.alerts[0].startsAt='bad';assert.throws(()=>alertsFromWebhook(b,config));
});
test('duplicate alert does not reset spending or recovery attempts',()=>{
  const s=new Store(':memory:');const a=makeAlert();const i=s.ingest(a).incident;i.spent=1;i.attempts=1;s.put(i);
  const duplicate=s.ingest(a);assert.equal(duplicate.fresh,false);assert.equal(duplicate.incident.spent,1);
  assert.equal(duplicate.incident.attempts,1);s.db.close();
});
test('email and webhook correlate without creating a second budget',()=>{
  const s=new Store(':memory:');const a=makeAlert();s.ingest(a);
  assert.equal(s.ingest({...a,key:'other',source:'alertmanager'}).fresh,false);
  assert.equal(s.list().length,1);s.db.close();
});
test('structured resolution wins when an email arrived first and a model is in flight',()=>{
  const s=new Store(':memory:');const a=makeAlert();s.ingest(a);
  const structured={...a,key:'structured',source:'alertmanager'};
  const i=s.ingest(structured).incident;i.status='investigating';s.put(i);
  s.ingest({...structured,status:'resolved'});
  i.spent=0.01;s.put(i);
  assert.ok(s.get(i.id)?.resolvedAt);assert.equal(s.list().length,1);s.db.close();
});
test('ambiguous email cannot select an arbitrary host or service',()=>{
  const c={...config,services:[service,{...service,name:'top-scores-web'}]};
  const a=alertFromEmail({id:'1',receivedAt:new Date().toISOString(),text:'top-scores and top-scores-web are down'},c);
  assert.equal(a.service,'unknown');
  assert.throws(()=>alertFromEmail({id:'1',receivedAt:'2000-01-01',text:'top-scores'},c));
});
test('resolved duplicate stops queued recovery',()=>{
  const s=new Store(':memory:');const a=makeAlert();s.ingest(a);
  assert.equal(s.ingest({...a,status:'resolved'}).incident.status,'source_resolved');s.db.close();
});
test('interrupted execution requires review instead of replay',()=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;i.status='acting';s.put(i);s.recover();
  assert.equal(s.get(i.id)?.status,'interrupted');s.db.close();
});
test('redacts credentials and email addresses from evidence',()=>{
  const text=redact('Authorization: Bearer sk-secret01234567890 password=hunter2 me@example.com mongodb://user:pass@localhost');
  assert.ok(!text.includes('hunter2'));assert.ok(!text.includes('me@example.com'));assert.ok(!text.includes('user:pass'));
});
test('model cannot add shell commands or unregistered actions',()=>{
  assert.throws(()=>parseDecision(JSON.stringify({diagnosis:'x',action:'shell',reason:'x',confidence:'high'})));
  assert.throws(()=>parseDecision(JSON.stringify({diagnosis:'x',action:'restart',reason:'x',confidence:'high',command:'rm -rf /'})));
});
test('cloud request reserves both input and maximum output before spending',()=>{
  const p={kind:'openai' as const,model:'x',inputPerMillion:1,outputPerMillion:5,maxOutputTokens:1000,timeoutMs:1000};
  assert.ok(reserveCost(p,'hello')>0.013);
  assert.throws(()=>reserveCost({...p,inputPerMillion:0},'hello'));
});
test('budget prevents any cloud API transmission',async()=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  process.env.AIOPS_TEST_API_KEY='test';
  const d=await diagnose({...config,budgetUsd:0,providers:[{kind:'openai',model:'test',keyEnv:'AIOPS_TEST_API_KEY',
    inputPerMillion:1,outputPerMillion:5,timeoutMs:1000,maxOutputTokens:1000}]},s,i,{},[]);
  assert.equal(d.action,'none');assert.equal(i.spent,0);assert.ok(s.events(i.id).some(e=>e.kind==='budget_limit'));
  delete process.env.AIOPS_TEST_API_KEY;s.db.close();
});
test('paused service does not investigate or act',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());s.set('paused:top-scores',true);
  const e=new Engine(config,s,async()=>{throw new Error('Must not run');},decision);
  await e.tick();assert.equal(s.list()[0].status,'queued');s.db.close();
});
test('wrong incident owner never executes',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());
  const e=new Engine({...config,host:'sky'},s,async()=>{throw new Error('Must not run');},decision);
  await e.tick();assert.equal(s.list()[0].status,'other_host');s.db.close();
});
test('unreachable target is reported without recovery',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());
  const e=new Engine(config,s,async()=>{throw new Error('SSH unreachable');},decision);
  await e.tick();assert.equal(s.list()[0].status,'unreachable');s.db.close();
});
test('healthy service with alert needs approval before a restart',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());let actions=0;
  const e=new Engine(config,s,async(_c,_s,op)=>{if(op!=='inspect')actions++;return {...unhealthy,healthy:true};},decision);
  await e.tick();assert.equal(s.list()[0].status,'needs_approval');assert.equal(actions,0);s.db.close();
});
test('low confidence selection requires an exact, unexpired approval',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());
  const e=new Engine(config,s,async()=>unhealthy,async()=>({...await decision(),confidence:'low'}));
  await e.tick();const i=s.list()[0];assert.equal(i.status,'needs_approval');
  await assert.rejects(e.approve(i.id,'redeploy'));
  i.approvalExpires='2000-01-01';s.put(i);await assert.rejects(e.approve(i.id,'restart'));s.db.close();
});
test('fresh pause during diagnosis prevents recovery',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());let mutations=0;
  const e=new Engine(config,s,async(_c,_s,op)=>{if(op!=='inspect')mutations++;return unhealthy;},
    async()=>{s.set('paused',true);return decision();});
  await e.tick();assert.equal(mutations,0);assert.equal(s.list()[0].status,'paused');s.db.close();
});
test('disposable HTTP service recovers and passes three fresh checks',async t=>{
  let healthy=false,actions=0;
  const fixture=createServer((_req,res)=>{res.writeHead(healthy?200:503);res.end('fixture');});
  await new Promise<void>(r=>fixture.listen(0,'127.0.0.1',r));t.after(()=>fixture.close());
  const address=fixture.address();assert.ok(address && typeof address==='object');
  const c={...config,services:[{...service,publicUrl:`http://127.0.0.1:${address.port}`} ]};
  const s=new Store(':memory:');s.ingest(makeAlert());
  const e=new Engine(c,s,async(_c,_s,op)=>{
    if(op!=='inspect'){actions++;healthy=true;return {ok:true};}
    return {...unhealthy,healthy,status:{active:healthy}};
  },decision);
  await e.tick();assert.equal(actions,1);assert.equal(s.list()[0].status,'recovered');
  assert.equal(s.list()[0].verification.samples.length,3);s.db.close();
});
test('successful action with failing checks is never reported recovered',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert());
  const e=new Engine(config,s,async(_c,_s,op)=>op==='inspect'?unhealthy:{ok:true},decision);
  await e.tick();assert.equal(s.list()[0].status,'still_failing');s.db.close();
});
test('unknown alertmanager state blocks automatic recovery',async()=>{
  const s=new Store(':memory:');s.ingest(makeAlert({source:'alertmanager'}));let actions=0;
  const e=new Engine(config,s,async(_c,_s,op)=>{if(op!=='inspect')actions++;return unhealthy;},decision);
  await e.tick();assert.equal(actions,0);assert.equal(s.list()[0].status,'needs_approval');s.db.close();
});
test('silenced alert cannot authorize automatic recovery',async t=>{
  const s=new Store(':memory:');const alert=makeAlert({source:'alertmanager'});s.ingest(alert);
  t.mock.method(globalThis,'fetch',async()=>Response.json([{labels:{alertname:alert.name},
    startsAt:alert.startsAt,status:{state:'suppressed'}}]));
  let actions=0;
  const e=new Engine(config,s,async(_c,_s,op)=>{if(op!=='inspect')actions++;return unhealthy;},decision);
  await e.tick();assert.equal(actions,0);assert.equal(s.list()[0].status,'needs_approval');s.db.close();
});
test('queue decodes Cloudflare JSON and acknowledges only persisted messages',async t=>{
  const s=new Store(':memory:');
  const envelope={id:'email-1',receivedAt:new Date().toISOString(),text:'top-scores is unavailable'};
  const message:{body:unknown;metadata:Record<string,string>;lease_id:string}={body:envelope,
    metadata:{'CF-Content-Type':'json'},lease_id:'lease-1'};
  const calls:any[]=[];
  t.mock.method(globalThis,'fetch',async(url:string,options:any)=>{
    calls.push({url,body:JSON.parse(options.body)});
    if(url.endsWith('/pull'))return Response.json({result:{messages:[message]}});
    assert.equal(s.list().length,1);
    return Response.json({success:true});
  });
  for(const body of [envelope,JSON.stringify(envelope),Buffer.from(JSON.stringify(envelope)).toString('base64')]) {
    message.body=body;
    calls.length=0;
    await pollQueue({...config,queue:{account:'test',id:'test',token:'test'}},s);
    assert.deepEqual(calls[1].body,{acks:[{lease_id:'lease-1'}],retries:[]});
  }
  calls.length=0;
  t.mock.method(s,'ingest',()=>{throw new Error('disk unavailable');});
  await assert.rejects(pollQueue({...config,queue:{account:'test',id:'test',token:'test'}},s));
  assert.equal(calls.length,1);s.db.close();
});
test('reconciliation ingests active alerts and excludes suppressed ones',async t=>{
  const s=new Store(':memory:');const active=webhook().alerts[0];
  t.mock.method(globalThis,'fetch',async()=>Response.json([
    {...active,status:{state:'active'}},
    {...active,labels:{...active.labels,alertname:'SilencedFailure'},status:{state:'suppressed'}}
  ]));
  await reconcileAlerts(config,s);assert.equal(s.list().length,1);s.db.close();
});
test('dashboard requires login, same-origin controls, and webhook authentication',async t=>{
  const s=new Store(':memory:');const e=new Engine(config,s);
  const c={...config};const server=createApp(c,s,e);
  await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
  t.after(()=>{server.close();s.db.close();});
  const address=server.address();assert.ok(address&&typeof address==='object');
  const base=`http://127.0.0.1:${address.port}`;c.publicUrl=base;
  assert.equal((await fetch(base+'/api/state')).status,401);
  assert.equal((await fetch(base+'/webhooks/alertmanager',{method:'POST',body:'{}'})).status,401);
  const login=await fetch(base+'/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:c.dashboardPassword})});
  const cookie=login.headers.get('set-cookie')!.split(';')[0];assert.equal(login.status,200);
  assert.equal((await fetch(base+'/api/state',{headers:{cookie}})).status,200);
  assert.equal((await fetch(base+'/api/controls',{method:'POST',headers:{cookie},body:'{"paused":true}'})).status,403);
  const control=await fetch(base+'/api/controls',{method:'POST',headers:{cookie,Origin:base,'X-AIOps-Control':'1','Content-Type':'application/json'},body:'{"paused":true}'});
  assert.equal(control.status,200);assert.equal(s.setting('paused',false),true);
});
