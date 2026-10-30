import test from 'node:test';
import assert from 'node:assert/strict';
import {Store} from '../lib/store.ts';
import {metrics} from '../lib/metrics.ts';
import {HealthMonitor} from '../lib/health.ts';
import {createApp,pollQueue} from '../server.ts';
import {Engine} from '../lib/engine.ts';
import type {Config} from '../lib/types.ts';

const config={host:'mini',services:[{name:'worker',host:'mini'}],webhookToken:'test-token',
  peers:{},notification:{}} as unknown as Config;
test('unknown and stale health cannot be exported as healthy; failures and backlog remain visible',()=>{
  const store=new Store(':memory:');
  const health=new HealthMonitor(config);
  health.reports=[{name:'worker',host:'mini',status:'healthy',checkedAt:'2000-01-01T00:00:00Z',checks:{}}];
  store.db.prepare('INSERT INTO notifications(incident,channel,data,attempts) VALUES(?,?,?,?)').run('test','email','{}',8);
  const output=metrics(config,store,health);
  assert.match(output,/aiops_service_healthy\{service="worker"\} 0/);
  assert.match(output,/aiops_notifications_failed\{service="aiops"\} 1/);
  assert.match(output,/aiops_webhook_canary_timestamp_seconds\{service="aiops"\} 0/);
  store.db.close();
});
test('canary requires authenticated live webhook, creates no incident and metrics require authentication',async()=>{
  const store=new Store(':memory:');
  const server=createApp(config,store,new Engine(config,store));
  await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url=`http://127.0.0.1:${(server.address() as any).port}`;
  try {
    assert.equal((await fetch(url+'/metrics')).status,401);
    const headers={Authorization:'Bearer test-token','Content-Type':'application/json'};
    const body=JSON.stringify({alerts:[{labels:{alertname:'AIOpsPipelineCanary',host:'mini'},
      status:'firing',startsAt:new Date().toISOString(),endsAt:'0001-01-01T00:00:00Z'}]});
    assert.equal((await fetch(url+'/webhooks/alertmanager',{method:'POST',body})).status,401);
    assert.equal(store.setting('monitor:webhook_canary',0),0);
    assert.equal((await fetch(url+'/webhooks/alertmanager',{method:'POST',headers,body})).status,202);
    assert.ok(store.setting('monitor:webhook_canary',0)>0);
    assert.equal(store.list().length,0);
    assert.equal((await fetch(url+'/metrics',{headers})).status,200);
  } finally {server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));store.db.close();}
});

test('queue canary is acknowledged without an incident and failed polling cannot refresh health',async()=>{
  const store=new Store(':memory:');
  const previous=globalThis.fetch;
  let acknowledged=false;
  const sentAt=new Date().toISOString();
  const cfg={...config,queue:{account:'fixture',id:'fixture',token:'fixture'}};
  try {
    globalThis.fetch=async(input,init)=>{
      if(String(input).endsWith('/ack')) {
        acknowledged=JSON.parse(String(init?.body)).acks[0].lease_id==='lease';
        return Response.json({success:true});
      }
      return Response.json({result:{messages:[{id:'test',lease_id:'lease',
        body:{type:'aiops-queue-canary',sentAt}}]}});
    };
    await pollQueue(cfg,store);
    assert.equal(acknowledged,true);
    assert.equal(store.list().length,0);
    assert.equal(store.setting('monitor:email_canary',0),Date.parse(sentAt));
    const before=store.setting('monitor:queue_poll',0);
    globalThis.fetch=async()=>new Response('',{status:503});
    await assert.rejects(pollQueue(cfg,store));
    assert.equal(store.setting('monitor:queue_poll',0),before);
  } finally {globalThis.fetch=previous;store.db.close();}
});

test('updater versions and freshness are exported without arbitrary version labels',()=>{
  const store=new Store(':memory:');
  const health=new HealthMonitor(config);
  health.reports=[{name:'worker',host:'mini',status:'unhealthy',checkedAt:new Date().toISOString(),checks:{ollamaUpdateHealthy:false},
    ollamaUpdate:{installedVersion:'0.40.12',latestVersion:'0.40.13',lastCheckAt:123,lastUpgradeAt:100}}];
  try {
    let output=metrics(config,store,health);
    assert.match(output,/aiops_service_healthy\{service="worker"\} 0/);
    assert.match(output,/aiops_ollama_update_info\{service="worker",installed="0.40.12",latest="0.40.13"\} 1/);
    assert.match(output,/aiops_ollama_update_last_check_timestamp_seconds\{service="worker"\} 123/);
    health.reports[0].ollamaUpdate!.latestVersion='untrusted text';
    output=metrics(config,store,health);
    assert.doesNotMatch(output,/aiops_ollama_update_info|untrusted text/);
  } finally {store.db.close();}
});
