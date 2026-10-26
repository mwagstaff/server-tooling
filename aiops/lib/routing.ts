import type {Alert,Config} from './types.ts';
import {alertsFromWebhook,sameAlert} from './alerts.ts';
import {boundedBody} from './security.ts';
export function applicationOwner(config:Config,a:Alert) {
  return config.services.find(s=>s.name===a.service && s.host===a.host)?.owner;
}
export async function relayApplication(config:Config,raw:any,a:Alert):Promise<boolean> {
  const owner=applicationOwner(config,a);
  if(!owner || owner===config.host)return false;
  const base=config.peers[owner];
  if(!base || !config.peerToken)throw new Error('Owning responder relay unavailable');
  // Alertmanager firing webhooks may carry the zero-time endsAt sentinel.
  // Obtain the real expiry from the source instead of inventing a lifetime.
  if(a.status==='firing' && !(Date.parse(raw.endsAt)>=Date.parse(a.startsAt))) {
    const source=await fetch(config.alertmanagerUrl+'/api/v2/alerts',{signal:AbortSignal.timeout(5000),redirect:'error'});
    if(!source.ok)throw new Error('Source expiry unavailable');
    const snapshot=JSON.parse(await boundedBody(source,1024*1024));
    const match=snapshot.find((item:any)=>{
      try{return alertsFromWebhook({alerts:[item]},config).some(b=>sameAlert(a,b));}catch{return false;}
    });
    if(!match || !(Date.parse(match.endsAt)>=Date.parse(a.startsAt)))throw new Error('Source expiry unavailable');
    raw={...raw,endsAt:match.endsAt};
  }
  const r=await fetch(base+'/api/relay-alerts',{method:'POST',headers:{Authorization:'Bearer '+config.peerToken,'Content-Type':'application/json'},
    body:JSON.stringify({alerts:[{...raw,labels:{...raw.labels,host:a.host,service:a.service}}]}),signal:AbortSignal.timeout(10000),redirect:'error'});
  await boundedBody(r,10000);
  if(!r.ok)throw new Error('Owning responder relay failed: HTTP '+r.status);
  return true;
}
export async function receiveRelay(config:Config,body:any) {
  const parsed=alertsFromWebhook(body,config);
  if(parsed.length!==body.alerts?.length || !parsed.length || parsed.some(a=>applicationOwner(config,a)!==config.host))
    throw new Error('Relay requires registered applications owned by this responder');
  const payload=body.alerts.map((raw:any,index:number)=>{
    const a=parsed[index];
    const end=Date.parse(raw.endsAt);
    if(!Number.isFinite(end) || end<Date.parse(a.startsAt))throw new Error('Relay requires valid source expiry');
    return {labels:{...raw.labels,host:a.host,service:a.service},annotations:raw.annotations,startsAt:a.startsAt,
      endsAt:a.status==='resolved'?new Date(Math.min(Date.now(),end)).toISOString():raw.endsAt};
  });
  // Inject into the owner's real Alertmanager so silences, source checks and
  // ordinary notification routing all remain authoritative. No arbitrary URL.
  const r=await fetch(config.alertmanagerUrl+'/api/v2/alerts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(5000),redirect:'error'});
  await boundedBody(r,10000);
  if(!r.ok)throw new Error('Owner Alertmanager rejected relay: HTTP '+r.status);
}
