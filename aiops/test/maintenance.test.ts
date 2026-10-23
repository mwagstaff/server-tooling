import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Store} from '../lib/store.ts';
import {Engine} from '../lib/engine.ts';
import {beginMaintenance} from '../lib/maintenance.ts';
import {createApp} from '../server.ts';
import type {Config,Alert} from '../lib/types.ts';

const config:Config={host:'mini',listen:'127.0.0.1',port:0,stateDir:'/tmp',publicUrl:'http://localhost',
  dashboardPassword:'password',webhookToken:'secret',peerToken:'peer',peers:{},ssh:{},
  services:[{name:'test-api',host:'sky',owner:'mini',unit:'test',directory:'/tmp',logs:[],healthUrl:'http://localhost',
    dependencies:[],autoActions:[],approvalActions:[],group:'test'}],
  providers:[],budgetUsd:2,automatic:false,cooldownSeconds:900,maxActions:2,alertmanagerUrl:'http://localhost:1',
  prometheusUrl:'http://localhost:1',verifyDelayMs:1,staleAfterMs:86400000,notification:{}};
const payload={host:'sky',services:['test-api'],seconds:180,reason:'Deployment test'};
const alert:Alert={host:'sky',service:'test-api',source:'email',key:'test',name:'EmailAlert',summary:'Unavailable',
  status:'firing',startsAt:new Date().toISOString(),receivedAt:new Date().toISOString(),labels:{}};

test('service silence is exact, bounded and preserves watchdog routes',async t=>{
  const s=new Store(':memory:');t.after(()=>s.db.close());
  const bodies:any[]=[];
  t.mock.method(globalThis,'fetch',async(_url:any,options:any)=>{bodies.push(JSON.parse(options.body));return Response.json({silenceID:'id'});});
  const w=await beginMaintenance(config,s,payload);
  assert.equal(w.endsAt-w.startsAt,180000);
  assert.deepEqual(bodies[0].matchers,[{name:'host',value:'sky',isRegex:false,isEqual:true},
    {name:'alertname',value:'MonitoringWatchdog|AIOpsPipelineCanary',isRegex:true,isEqual:false},
    {name:'service',value:'test-api',isRegex:false,isEqual:true}]);
  assert.equal(s.maintenance('sky','test-api'),true);
  assert.equal(s.maintenance('sky','unrelated'),false);
  assert.equal(s.maintenance('mini','test-api'),false);
  assert.equal(s.maintenance('sky','test-api',w.endsAt),false);
});

test('host maintenance covers unknown host alerts but rejects wrong host and invalid scopes',async t=>{
  const s=new Store(':memory:');t.after(()=>s.db.close());
  t.mock.method(globalThis,'fetch',async()=>Response.json({silenceID:'id'}));
  await beginMaintenance(config,s,{...payload,services:[],seconds:600});
  assert.equal(s.maintenance('sky','unknown'),true);
  for(const change of [{host:'mini'},{host:'other'},{services:['unregistered']},{seconds:0},{seconds:1801},{seconds:1.5}])
    await assert.rejects(beginMaintenance(config,s,{...payload,...change}));
});

test('failed silence does not claim maintenance and active recovery prevents it',async t=>{
  const s=new Store(':memory:');t.after(()=>s.db.close());
  t.mock.method(globalThis,'fetch',async()=>new Response('',{status:503}));
  await assert.rejects(beginMaintenance(config,s,payload));
  assert.equal(s.maintenance('sky','test-api'),false);
  const i=s.ingest(alert).incident;i.status='acting';s.put(i);
  await assert.rejects(beginMaintenance(config,s,payload),/already running/);
});

test('maintenance defers email investigations, then clears healthy service without model or notifications',async t=>{
  const s=new Store(':memory:');t.after(()=>s.db.close());
  const window={host:'sky',services:['test-api'],endsAt:Date.now()+180000};
  s.set('maintenance:windows',[window]);s.ingest(alert);
  let inspections=0;
  const e=new Engine(config,s,async()=>{inspections++;return {healthy:true,status:{active:true},logs:''};},
    async()=>{throw new Error('Model must not be called');});
  await e.tick();assert.equal(inspections,0);assert.equal(s.list()[0].status,'queued');
  s.set('maintenance:windows',[{...window,endsAt:Date.now()-1}]);
  await e.tick();assert.equal(inspections,1);assert.equal(s.list()[0].status,'healthy');
  assert.equal(s.db.prepare('SELECT count(*) AS n FROM notifications').get()?.n,0);
});

test('persistent failures resume investigation after maintenance expires',async t=>{
  const s=new Store(':memory:');t.after(()=>s.db.close());
  s.set('maintenance:windows',[{host:'sky',services:['test-api'],endsAt:Date.now()+180000}]);s.ingest(alert);
  let models=0;
  const e=new Engine(config,s,async()=>({healthy:false,status:{active:false},logs:''}),async()=>{
    models++;return {action:'none',diagnosis:'Still failing',reason:'Review required',confidence:'high'};
  });
  await e.tick();assert.equal(models,0);
  s.set('maintenance:windows',[]);await e.tick();assert.equal(models,1);assert.equal(s.list()[0].status,'needs_review');
});

test('maintenance arriving during evidence collection prevents model and actions',async t=>{
  const s=new Store(':memory:');t.after(()=>s.db.close());s.ingest(alert);
  const e=new Engine(config,s,async()=>{
    s.set('maintenance:windows',[{host:'sky',services:['test-api'],endsAt:Date.now()+180000}]);
    return {healthy:false,status:{active:false},logs:''};
  },async()=>{throw new Error('Model must not run');});
  await e.tick();assert.equal(s.list()[0].status,'queued');
});

test('maintenance endpoint requires machine credentials',async t=>{
  const s=new Store(':memory:');const app=createApp(config,s,new Engine(config,s));
  await new Promise<void>(r=>app.listen(0,'127.0.0.1',r));
  t.after(()=>{app.close();s.db.close();});
  const address=app.address();assert.ok(address&&typeof address==='object');
  const response=await fetch(`http://127.0.0.1:${address.port}/api/maintenance`,{method:'POST',body:JSON.stringify(payload)});
  assert.equal(response.status,401);assert.equal(s.maintenance('sky','test-api'),false);
});
