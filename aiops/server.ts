import {createServer, type IncomingMessage, type ServerResponse} from 'node:http';
import {readFileSync} from 'node:fs';
import {randomBytes,createHmac} from 'node:crypto';
import {loadConfig} from './lib/config.ts';
import {Store} from './lib/store.ts';
import {Engine} from './lib/engine.ts';
import {alertsFromWebhook,alertFromEmail} from './lib/alerts.ts';
import {boundedBody,equal,redact} from './lib/security.ts';
import {flushNotifications} from './lib/notifications.ts';
import {HealthMonitor,fleetHealth,HEALTH_INTERVAL_MS} from './lib/health.ts';
import type {Config,Alert} from './lib/types.ts';
import {metrics} from './lib/metrics.ts';
import {beginMaintenance} from './lib/maintenance.ts';
import {pathToFileURL} from 'node:url';

const assets:Record<string,[string,string]> = {
  '/':['index.html','text/html; charset=utf-8'],
  '/app.js':['app.js','text/javascript; charset=utf-8'],
  '/style.css':['style.css','text/css; charset=utf-8']
};
async function readBody(req:IncomingMessage) {
  const chunks=[];let total=0;
  for await(const chunk of req) {
    total+=chunk.length;
    if(total>256000) throw new Error('Request body too large');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString() || '{}');
}
export function createApp(config:Config, store:Store, engine:Engine, health=new HealthMonitor(config)) {
  const failures=new Map<string,{at:number;count:number}>();
  const sessionKey=randomBytes(32);
  function session(token:string) {
    const [payload,signature]=token.split('.');
    if(!payload||!signature||!equal(createHmac('sha256',sessionKey).update(payload).digest('hex'),signature)) return false;
    return Number(payload)>Date.now();
  }
  function cookie(req:IncomingMessage) {
    return req.headers.cookie?.match(/(?:^|; )aiops_session=([^;]+)/)?.[1] || '';
  }
  function send(res:ServerResponse,status:number,data:unknown) {
    res.writeHead(status,{'Content-Type':'application/json; charset=utf-8'});
    res.end(JSON.stringify(data));
  }
  return createServer(async(req,res)=>{
    res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');
    res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    try {
      const url=new URL(req.url || '/','http://localhost');
      if(req.method==='GET' && url.pathname==='/healthcheck') return send(res,200,{status:'ok'});
      if(req.method==='GET' && assets[url.pathname]) {
        const [file,type]=assets[url.pathname];
        res.writeHead(200,{'Content-Type':type});
        return res.end(readFileSync(new URL(`./public/${file}`,import.meta.url)));
      }
      const bearer=req.headers.authorization?.startsWith('Bearer ')?req.headers.authorization.slice(7):'';
      if(req.method==='POST' && url.pathname==='/api/maintenance') {
        if(!bearer || !(equal(bearer,config.webhookToken) || config.peerToken && equal(bearer,config.peerToken)))
          return send(res,401,{error:'Unauthorized'});
        return send(res,201,await beginMaintenance(config,store,await readBody(req)));
      }
      if(req.method==='GET' && url.pathname==='/metrics') {
        if(!bearer || !equal(bearer,config.webhookToken)) return send(res,401,{error:'Unauthorized'});
        res.writeHead(200,{'Content-Type':'text/plain; version=0.0.4'});
        return res.end(metrics(config,store,health));
      }
      if(req.method==='POST' && ['/webhooks/alertmanager','/webhooks/email'].includes(url.pathname)) {
        if(!bearer || !equal(bearer,config.webhookToken)) return send(res,401,{error:'Unauthorized'});
        const body=await readBody(req);
        if(url.pathname.endsWith('alertmanager') && Array.isArray(body.alerts) && body.alerts.some((a:any)=>
          a.labels?.alertname==='AIOpsPipelineCanary' && a.labels?.host===config.host &&
          a.status==='firing' && Number.isFinite(Date.parse(a.startsAt)) && Date.parse(a.startsAt)<=Date.now()+60000)) store.set('monitor:webhook_canary',Date.now());
        const alerts=url.pathname.endsWith('email')?[alertFromEmail(body,config)]:alertsFromWebhook(body,config);
        for(const a of alerts) store.ingest(a);
        return send(res,202,{accepted:alerts.length});
      }
      if(req.method==='GET' && url.pathname==='/api/peer') {
        if(!config.peerToken || !bearer || !equal(bearer,config.peerToken)) return send(res,401,{error:'Unauthorized'});
        return send(res,200,{host:config.host,incidents:store.list(),paused:store.setting('paused',false),serviceHealth:health.reports});
      }
      if(req.method==='POST' && url.pathname==='/api/login') {
        const ip=req.socket.remoteAddress || '';
        let rate=failures.get(ip);
        if(!rate||Date.now()-rate.at>300000) {rate={at:Date.now(),count:0};failures.set(ip,rate);}
        if(rate.count>=10) return send(res,429,{error:'Too many attempts. Try in five minutes.'});
        const body=await readBody(req);
        if(typeof body.password!=='string'||!equal(body.password,config.dashboardPassword)) {
          rate.count++;return send(res,401,{error:'Incorrect password'});
        }
        const expires=String(Date.now()+8*3600000);
        const token=`${expires}.${createHmac('sha256',sessionKey).update(expires).digest('hex')}`;
        res.setHeader('Set-Cookie',`aiops_session=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800${config.publicUrl.startsWith('https:')?'; Secure':''}`);
        return send(res,200,{ok:true});
      }
      if(!session(cookie(req))) return send(res,401,{error:'Sign in required'});
      if(req.method!=='GET') {
        // Browser mutations require a same-origin request plus a custom header.
        if(req.headers['x-aiops-control']!=='1' ||
          req.headers.origin!==new URL(config.publicUrl).origin)
          return send(res,403,{error:'Same-origin control request required'});
      }
      if(req.method==='GET' && url.pathname==='/api/state') {
        const peerResults=await Promise.all(Object.entries(config.peers).map(async([host,address])=>{
          try {
            const r=await fetch(address+'/api/peer',{headers:{Authorization:`Bearer ${config.peerToken}`},signal:AbortSignal.timeout(2500),redirect:'error'});
            if(!r.ok) throw new Error('Peer unavailable');
            const data=JSON.parse(await boundedBody(r,2*1024*1024));
            return {host,url:address,available:true,incidents:data.incidents,paused:data.paused,
              serviceHealth:(data.serviceHealth||[]).filter((s:any)=>s.host===host)};
          } catch {return {host,url:address,available:false,incidents:[]};}
        }));
        return send(res,200,{
          host:config.host,now:new Date().toISOString(),busy:engine.busy,
          paused:store.setting('paused',false),automatic:store.setting('automatic',config.automatic),
          budgetUsd:store.setting('budgetUsd',config.budgetUsd),
          providers:config.providers.map(p=>({kind:p.kind,model:p.model,configured:p.kind==='ollama'||Boolean(process.env[p.keyEnv || ''])})),
          services:config.services.map(s=>({name:s.name,host:s.host,owner:s.owner,autoActions:s.autoActions,
            paused:store.setting(`paused:${s.name}`,false)})),
          serviceHealth:fleetHealth(config.services,[...health.reports,...peerResults.flatMap(p=>p.serviceHealth||[])]),
          incidents:store.list(),peers:peerResults,
          notifications:{pushover:Boolean(config.notification.pushoverToken),email:Boolean(config.notification.smtpHost),
            pending:store.db.prepare('SELECT COUNT(*) AS n FROM notifications WHERE delivered=0').get()?.n},
          emailIntake:Boolean(config.queue)
        });
      }
      const match=url.pathname.match(/^\/api\/incidents\/([a-f0-9-]+)(?:\/(approve|reject))?$/);
      if(match) {
        const i=store.get(match[1]);
        if(!i) return send(res,404,{error:'Incident not found'});
        if(req.method==='GET' && !match[2]) return send(res,200,{incident:i,events:store.events(i.id)});
        if(req.method==='POST' && match[2]==='approve') {
          const body=await readBody(req);
          await engine.approve(i.id,body.action);
          return send(res,200,{ok:true});
        }
        if(req.method==='POST' && match[2]==='reject') {
          if(i.status!=='needs_approval') return send(res,409,{error:'No pending approval'});
          i.status='rejected';store.put(i);store.event(i.id,'rejected',{});
          return send(res,200,{ok:true});
        }
      }
      if(req.method==='POST' && url.pathname==='/api/controls') {
        const body=await readBody(req);
        if(body.service && !config.services.some(s=>s.name===body.service&&s.owner===config.host))
          return send(res,400,{error:'Service is not owned by this host'});
        if(body.budgetUsd!==undefined && (!Number.isFinite(body.budgetUsd)||body.budgetUsd<0||body.budgetUsd>100))
          throw new Error('Budget must be between $0 and $100');
        if(typeof body.paused==='boolean') store.set(body.service?`paused:${body.service}`:'paused',body.paused);
        if(typeof body.automatic==='boolean') store.set('automatic',body.automatic);
        if(body.budgetUsd!==undefined) {
          store.set('budgetUsd',body.budgetUsd);
        }
        store.event('controls','changed',body);
        return send(res,200,{ok:true});
      }
      if(req.method==='POST' && url.pathname==='/api/logout') {
        res.setHeader('Set-Cookie','aiops_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
        return send(res,200,{ok:true});
      }
      send(res,404,{error:'Not found'});
    } catch(e) {send(res,400,{error:redact(String(e)).slice(0,500)});}
  });
}

export async function pollQueue(config:Config,store:Store) {
  if(!config.queue) return;
  const q=config.queue;
  const base=`https://api.cloudflare.com/client/v4/accounts/${q.account}/queues/${q.id}/messages`;
  const headers={'Authorization':`Bearer ${q.token}`,'Content-Type':'application/json'};
  const r=await fetch(base+'/pull',{method:'POST',headers,body:JSON.stringify({batch_size:5,visibility_timeout_ms:30000}),
    signal:AbortSignal.timeout(10000)});
  if(!r.ok) throw new Error(`Queue pull HTTP ${r.status}`);
  const result=JSON.parse(await boundedBody(r,512000));
  if(result.success===false || !Array.isArray(result.result?.messages)) throw new Error('Invalid queue pull response');
  const ack:string[]=[];
  for(const message of result.result?.messages || []) {
    let alert:Alert;
    try {
      const contentType=message.metadata?.['CF-Content-Type'];
      let value=message.body;
      if(typeof value==='string') {
        try { value=JSON.parse(value); }
        catch(e) {
          if(!['json','bytes'].includes(contentType)) throw e;
          value=JSON.parse(Buffer.from(value,'base64').toString('utf8'));
        }
      }
      if(value?.type==='aiops-queue-canary') {
        const timestamp=Date.parse(value.sentAt);
        if(Number.isFinite(timestamp) && timestamp<=Date.now()+60000 && Date.now()-timestamp<900000)
          store.set('monitor:email_canary',timestamp);
        ack.push(message.lease_id);continue;
      }
      alert=alertFromEmail(value,config);
      const service=config.services.find(s=>s.name===alert.service);
      if(service && service.owner!==config.host) throw new Error('Email delivered to wrong host queue');
    } catch(e) {
      store.event('email','intake_rejected',{messageId:message.id,error:redact(String(e))});
      // Poison / stale messages cannot trigger actions. Record and acknowledge.
      ack.push(message.lease_id);
      continue;
    }
    // Storage failures must leave the message unacknowledged for redelivery.
    store.ingest(alert);
    ack.push(message.lease_id);
  }
  if(ack.length) {
    const a=await fetch(base+'/ack',{method:'POST',headers,body:JSON.stringify({acks:ack.map(lease_id=>({lease_id})),retries:[]}),signal:AbortSignal.timeout(10000)});
    if(!a.ok) throw new Error(`Queue acknowledge HTTP ${a.status}`);
  }
  store.set('monitor:queue_poll',Date.now());
}

export async function reconcileAlerts(config:Config,store:Store) {
  const r=await fetch(`${config.alertmanagerUrl}/api/v2/alerts?active=true&silenced=false&inhibited=false`,
    {signal:AbortSignal.timeout(5000),redirect:'error'});
  if(!r.ok) throw new Error(`Alert reconciliation HTTP ${r.status}`);
  const active=JSON.parse(await boundedBody(r,1024*1024));
  if(!Array.isArray(active)) throw new Error('Invalid alert state');
  for(const item of active) {
    if(item.status?.state!=='active') continue;
    for(const alert of alertsFromWebhook({alerts:[item]},config)) store.ingest(alert);
  }
  store.set('monitor:reconcile',Date.now());
}

async function main() {
  process.umask(0o077);
  const config=loadConfig();
  const store=new Store(`${config.stateDir}/incidents.sqlite`);
  store.recover();
  const engine=new Engine(config,store);
  const health=new HealthMonitor(config);
  void health.refresh();
  const healthTimer=setInterval(()=>void health.refresh(),HEALTH_INTERVAL_MS);
  const server=createApp(config,store,engine,health);
  server.requestTimeout=200000;server.headersTimeout=10000;
  server.listen(config.port,config.listen,()=>console.log(`AIOps ${config.host} listening on ${config.listen}:${config.port}`));
  // The deployer's health check and local Alertmanager use loopback; the private
  // dashboard uses the separate Tailscale listener. Never bind the public NIC.
  const loopback=config.listen==='127.0.0.1'?undefined:createApp(config,store,engine,health);
  loopback?.listen(config.port,'127.0.0.1');
  let maintenance=false,closing=false,lastQueue=0,lastReconcile=0;
  const timer=setInterval(async()=>{
    if(closing) return;
    void engine.tick();
    if(maintenance) return;
    maintenance=true;
    try {
      const jobs=[()=>flushNotifications(config,store)];
      if(Date.now()-lastQueue>=30000) {lastQueue=Date.now();jobs.push(()=>pollQueue(config,store));}
      if(Date.now()-lastReconcile>=60000) {lastReconcile=Date.now();jobs.push(()=>reconcileAlerts(config,store));}
      for(const job of jobs) {
        try {await job();}
        catch(e) {console.error(redact(String(e)).slice(0,500));}
      }
    }
    finally {maintenance=false;}
  },5000);
  for(const signal of ['SIGTERM','SIGINT']) process.on(signal,()=>{
    closing=true;clearInterval(timer);clearInterval(healthTimer);server.close();loopback?.close();
    const drain=setInterval(()=>{if(!engine.busy&&!maintenance){clearInterval(drain);store.db.close();process.exit(0);}},250);
    setTimeout(()=>process.exit(1),160000).unref();
  });
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href || process.argv[1]?.endsWith('/server.mjs')) await main();
