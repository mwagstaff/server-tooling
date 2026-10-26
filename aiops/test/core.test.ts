import nodemailer from 'nodemailer';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {Store} from '../lib/store.ts';
import {Engine} from '../lib/engine.ts';
import {alertsFromWebhook,alertFromEmail} from '../lib/alerts.ts';
import {parseDecision,reserveCost,diagnose} from '../lib/providers.ts';
import {enqueueSummary,summaryHtml,flushNotifications} from '../lib/notifications.ts';
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

test('summary leads with source resolution without claiming service recovery',()=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  i.status='needs_review';i.diagnosis='Old startup lines.\nPossible restart loop.';s.put(i);
  s.ingest({...i.alert,status:'resolved'});
  enqueueSummary(config,s,i);
  const summary=s.events(i.id).find(e=>e.kind==='summary')!.data;
  assert.match(summary.title,/SOURCE CLEARED/);
  assert.match(summary.text,/^- Summary: SOURCE CLEARED. Service health not verified/);
  assert.ok(summary.text.split('\n').every((line:string)=>line.startsWith('- ')));
  assert.ok(!summary.text.includes('Final verification: {'));
  s.db.close();
});
test('uncertain assessment escalates once per provider within shared incident budget',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  process.env.AIOPS_TEST_API_KEY='test';t.after(()=>delete process.env.AIOPS_TEST_API_KEY);
  let calls=0;
  t.mock.method(globalThis,'fetch',async()=>{
    calls++;
    return Response.json({choices:[{message:{content:JSON.stringify({diagnosis:'Cause uncertain',action:'none',reason:'Review',confidence:calls===1?'low':'high'})}}],
      usage:{prompt_tokens:10,completion_tokens:10}});
  });
  const p={kind:'openai' as const,model:'test',keyEnv:'AIOPS_TEST_API_KEY',inputPerMillion:1,outputPerMillion:5,timeoutMs:1000,maxOutputTokens:1000};
  const d=await diagnose({...config,providers:[p,p]},s,i,{},[]);
  assert.equal(calls,2);assert.equal(d.confidence,'high');assert.ok(i.spent<2);
  assert.equal(s.events(i.id).filter(e=>e.kind==='investigation_escalated').length,1);
  s.db.close();
});
test('escalation preserves uncertain assessment when remaining budget cannot reserve another request',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  process.env.AIOPS_TEST_API_KEY='test';t.after(()=>delete process.env.AIOPS_TEST_API_KEY);
  let calls=0;
  t.mock.method(globalThis,'fetch',async()=>{
    calls++;return Response.json({choices:[{message:{content:JSON.stringify({diagnosis:'Unknown cause',action:'none',reason:'Review',confidence:'low'})}}]});
  });
  const p={kind:'openai' as const,model:'test',keyEnv:'AIOPS_TEST_API_KEY',inputPerMillion:1,outputPerMillion:5,timeoutMs:1000,maxOutputTokens:1000};
  const d=await diagnose({...config,budgetUsd:0.02,providers:[p,p]},s,i,{},[]);
  assert.equal(calls,1);assert.equal(d.diagnosis,'Unknown cause');
  assert.ok(s.events(i.id).some(e=>e.kind==='budget_limit'));s.db.close();
});
test('investigation supplies restart and response metrics to the model',async t=>{
  const s=new Store(':memory:');s.ingest(makeAlert());
  const queries:string[]=[];
  t.mock.method(globalThis,'fetch',async(url:URL)=>{
    queries.push(url.searchParams.get('query')!);
    return Response.json({status:'success',data:{result:[{metric:{},value:[1,'0']}]}});
  });
  const e=new Engine(config,s,async()=>unhealthy,async(_c,_s,_i,evidence)=>{
    assert.equal(evidence.metrics.restarts15m.samples[0].value[1],'0');
    return {diagnosis:'Unknown',action:'none',reason:'Review',confidence:'low'};
  });
  await e.tick();assert.equal(queries.length,3);assert.ok(queries.every(q=>q.includes('host="sky"')));s.db.close();
});

test('email delivers spaced HTML bullets and plain text, escaping alert content',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert({summary:'<img src=x onerror=alert(1)> & errors'})).incident;
  const c={...config,notification:{smtpHost:'smtp.test',emailTo:'test@example.com'}};
  enqueueSummary(c,s,i);
  let mail:any;let closed=false;
  t.mock.method(nodemailer,'createTransport',()=>({sendMail:async(value:any)=>{mail=value;},close:()=>{closed=true;}}) as any);
  await flushNotifications(c,s);
  assert.equal((mail.html.match(/<li /g)||[]).length,11);
  assert.match(mail.subject,/ · INC-\S{8}-\d{8}T\d{4}Z$/);
  assert.match(mail.text,/^- Ref: INC-/m);
  assert.match(mail.html,/<strong>Summary:<\/strong>/);
  assert.match(mail.html,/margin:0 0 12px/);
  assert.match(mail.html,/&lt;img src=x onerror=alert\(1\)&gt; &amp; errors/);
  assert.ok(!mail.html.includes('<img'));
  assert.match(mail.html,/<a href="http:\/\/localhost\/\?incident=/);
  assert.equal(mail.text.split('\n').length,11);
  assert.ok(closed);s.db.close();
});
test('HTML renderer also handles queued plain-text summaries and CRLF',()=>{
  const html=summaryHtml('- Summary: Review\r\n- Assessment: "quoted" <unsafe>');
  assert.equal((html.match(/<li /g)||[]).length,2);
  assert.match(html,/&quot;quoted&quot; &lt;unsafe&gt;/);
});

test('evidence gaps force escalation even when the local assessment claims high confidence',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  process.env.AIOPS_TEST_API_KEY='test';t.after(()=>delete process.env.AIOPS_TEST_API_KEY);
  let calls=0;
  t.mock.method(globalThis,'fetch',async()=>{calls++;return Response.json({choices:[{message:{content:JSON.stringify({diagnosis:'Possible disconnect',action:'none',reason:'Review',confidence:'high'})}}],usage:{prompt_tokens:1,completion_tokens:1}});});
  const p={kind:'openai' as const,model:'test',keyEnv:'AIOPS_TEST_API_KEY',inputPerMillion:1,outputPerMillion:5,timeoutMs:1000,maxOutputTokens:1000};
  const d=await diagnose({...config,providers:[p,p]},s,i,{qualityIssues:['Untimestamped logs.']},[]);
  assert.equal(calls,2);assert.equal(d.confidence,'low');assert.match(d.diagnosis,/Cause unconfirmed/);s.db.close();
});
test('summary dashboard links preserve exact service and incident window',()=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  i.diagnosis='First complete sentence. '+ 'Long trailing explanation '.repeat(40);s.put(i);
  enqueueSummary(config,s,i);
  const text=s.events(i.id).find(e=>e.kind==='summary')!.data.text;
  assert.match(text,/Assessment: First complete sentence. See incident for details./);
  const link=new URL(text.split('Service metrics: ')[1].split('\n')[0]);
  assert.equal(link.searchParams.get('var-service'),i.service);
  assert.equal(Number(link.searchParams.get('from')),Date.parse(i.alert.startsAt)-900000);
  assert.match(text,/monitoring-logs/);s.db.close();
});


test('source resolution queues one updated summary despite repeated webhooks',async t=>{
  const s=new Store(':memory:');
  const c={...config,notification:{smtpHost:'fixture',emailTo:'fixture@example.invalid'}};
  const server=createApp(c,s,new Engine(c,s));
  await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>{server.close();s.db.close();});
  const body=webhook();const a=alertsFromWebhook(body,c)[0];const i=s.ingest(a).incident;
  enqueueSummary(c,s,i);
  body.alerts[0].status='resolved';
  for(let n=0;n<2;n++) {
    const response=await fetch(`http://127.0.0.1:${(server.address() as any).port}/webhooks/alertmanager`,{
      method:'POST',headers:{Authorization:'Bearer '+c.webhookToken,'Content-Type':'application/json'},body:JSON.stringify(body)});
    assert.equal(response.status,202);
  }
  const rows=s.db.prepare('SELECT data FROM notifications').all();
  assert.equal(rows.length,2);
  assert.match(JSON.parse(rows[1].data as string).title,/SOURCE CLEARED/);
});

test('legacy Sky hostname is canonicalized without accepting another host',()=>{
  const b=webhook();b.alerts[0].labels.host='ubuntu-4gb-hel1-2';
  const [a]=alertsFromWebhook(b,config);
  assert.equal(a.host,'sky');assert.equal(a.labels.host,'sky');
});
test('one invalid alert cannot stall reconciliation of valid alerts',async t=>{
  const s=new Store(':memory:');const good=webhook().alerts[0];
  t.mock.method(globalThis,'fetch',async()=>Response.json([
    {...good,labels:{...good.labels,host:'mini'},status:{state:'active'}},
    {...good,status:{state:'active'}}
  ]));
  await reconcileAlerts(config,s);
  assert.equal(s.list().length,1);assert.equal(s.events('intake')[0].kind,'rejected_alert');
  assert.ok(s.setting('monitor:reconcile',0)>0);
  t.mock.method(s,'ingest',()=>{throw new Error('disk unavailable');});
  await assert.rejects(reconcileAlerts(config,s),/disk unavailable/);s.db.close();
});

test('source verification recognizes the legacy hostname after normalization',async t=>{
  const s=new Store(':memory:');const b=webhook();b.alerts[0].labels.host='ubuntu-4gb-hel1-2';
  const i=s.ingest(alertsFromWebhook(b,config)[0]).incident;
  t.mock.method(globalThis,'fetch',async()=>Response.json([{...b.alerts[0],status:{state:'active'}}]));
  assert.equal(await new Engine(config,s).alertStillFiring(i),true);s.db.close();
});


test('provider caps persist across investigations and total settings cannot exceed one dollar',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  process.env.AIOPS_TEST_API_KEY='test';t.after(()=>delete process.env.AIOPS_TEST_API_KEY);
  s.set('budgetUsd',2);let calls=0;
  t.mock.method(globalThis,'fetch',async()=>{calls++;throw new Error('timeout');});
  const p={kind:'openai' as const,model:'test',keyEnv:'AIOPS_TEST_API_KEY',inputPerMillion:1,outputPerMillion:5,timeoutMs:1000,maxOutputTokens:1000,budgetUsd:0.02};
  await diagnose({...config,providers:[p]},s,i,{},[]);
  const reserved=i.spent;
  await diagnose({...config,providers:[p]},s,s.get(i.id)!,{},[]);
  assert.equal(calls,1);assert.equal(s.get(i.id)!.spent,reserved);
  assert.ok(s.events(i.id).some(e=>e.kind==='provider_budget_limit'));
  i.spent=0.999;s.put(i);
  await diagnose({...config,providers:[{...p,budgetUsd:0.8}]},s,i,{},[]);
  assert.equal(calls,1);assert.ok(s.events(i.id).some(e=>e.kind==='budget_limit'));s.db.close();
});

test('Haiku hands uncertain assessment to Sonnet medium and accounts actual stage usage',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  process.env.AIOPS_TEST_API_KEY='test';t.after(()=>delete process.env.AIOPS_TEST_API_KEY);
  const requests:any[]=[];
  t.mock.method(globalThis,'fetch',async(_url:any,options:any)=>{
    const body=JSON.parse(options.body);requests.push(body);
    const decision={diagnosis:requests.length===1?'Uncertain dependency failure':'Evidence remains inconclusive',action:'none',reason:'Review required',confidence:requests.length===1?'medium':'high'};
    return Response.json({content:[{type:'text',text:JSON.stringify(decision)}],usage:{input_tokens:requests.length===1?100:200,output_tokens:requests.length===1?50:100}});
  });
  const common={keyEnv:'AIOPS_TEST_API_KEY',timeoutMs:1000,maxOutputTokens:1500};
  const providers=[{...common,kind:'anthropic' as const,model:'claude-haiku-4-5-20251001',inputPerMillion:1,outputPerMillion:5,budgetUsd:0.2},
    {...common,kind:'anthropic' as const,model:'claude-sonnet-5-5',reasoningEffort:'medium' as const,inputPerMillion:2,outputPerMillion:10,budgetUsd:0.8}];
  await diagnose({...config,providers},s,i,{},['none']);
  assert.equal(requests.length,2);assert.equal(requests[1].output_config.effort,'medium');
  assert.match(requests[1].messages[0].content,/Uncertain dependency failure/);
  assert.ok(Math.abs(i.spent-0.00175)<1e-8);
  const {providerSpent}=await import('../lib/budget.ts');
  assert.ok(Math.abs(providerSpent(s,i.id,'anthropic','claude-haiku-4-5-20251001')-0.00035)<1e-8);
  assert.ok(Math.abs(providerSpent(s,i.id,'anthropic','claude-sonnet-5-5')-0.0014)<1e-8);s.db.close();
});

test('exhausted Haiku allowance escalates directly to Sol without borrowing its budget',async t=>{
  const s=new Store(':memory:');const i=s.ingest(makeAlert()).incident;
  i.spent=0.199;s.put(i);s.event(i.id,'model_request',{provider:'anthropic',model:'haiku',reservedUsd:0.199});
  process.env.AIOPS_TEST_API_KEY='test';t.after(()=>delete process.env.AIOPS_TEST_API_KEY);
  const models:string[]=[];
  t.mock.method(globalThis,'fetch',async(_u:any,o:any)=>{
    models.push(JSON.parse(o.body).model);
    return Response.json({choices:[{message:{content:JSON.stringify({diagnosis:'No cause established',action:'none',reason:'Review',confidence:'high'})}}],usage:{prompt_tokens:100,completion_tokens:100}});
  });
  const p={keyEnv:'AIOPS_TEST_API_KEY',inputPerMillion:2,outputPerMillion:10,timeoutMs:1000,maxOutputTokens:1500};
  await diagnose({...config,providers:[{...p,kind:'anthropic',model:'haiku',budgetUsd:0.2},{...p,kind:'openai',model:'sol',budgetUsd:0.8}]},s,i,{},['none']);
  assert.deepEqual(models,['sol']);assert.ok(i.spent<1);s.db.close();
});

test('incident reference matches the Alertmanager fingerprint template and survives re-delivery',()=>{
  const raw={labels:{alertname:'TopScoresEloImportFailed',host:'sky',service:'top-scores',source:'club_elo_rankings'},
    annotations:{summary:'Club Elo import failed after retries'},status:'firing',
    startsAt:'2026-10-25T10:47:24.642Z',fingerprint:'3fa9c2d1e4b5a697'};
  const [a]=alertsFromWebhook({alerts:[raw]},config);
  assert.equal(a.ref,'INC-3fa9c2d1-20261025T1047Z');
  const s=new Store(':memory:');
  const legacy={...a};delete legacy.ref;
  const i=s.ingest(legacy).incident;assert.equal(i.alert.ref,undefined);
  assert.equal(s.ingest(a).incident.alert.ref,'INC-3fa9c2d1-20261025T1047Z');
  const [noFingerprint]=alertsFromWebhook({alerts:[{...raw,fingerprint:'not-hex'}]},config);
  assert.match(noFingerprint.ref!,/^INC-[0-9a-f]{8}-20261025T1047Z$/);
  s.db.close();
});
