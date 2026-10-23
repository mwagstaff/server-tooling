import type {Config} from './types.ts';
import type {Store} from './store.ts';
import {boundedBody} from './security.ts';

export interface MaintenanceWindow {
  host:string; services:string[]; startsAt:number; endsAt:number; reason:string; silenceIds:string[];
}
export async function beginMaintenance(config:Config,store:Store,body:any) {
  const {host,services,seconds,reason}=body;
  if(!['mini','sky'].includes(host) || host===config.host ||
     !Array.isArray(services) || services.length>50 ||
     !services.every((s:any)=>typeof s==='string' && (s==='aiops' || config.services.some(x=>x.name===s && x.host===host && x.owner===config.host))) ||
     !Number.isInteger(seconds) || seconds<30 || seconds>1800 ||
     typeof reason!=='string' || !reason.trim() || reason.length>200)
    throw new Error('Expected owned host, registered services (empty for host maintenance), 30–1800 seconds and reason');
  if(store.list().some(i=>i.host===host && (!services.length||services.includes(i.service)) && ['acting','verifying'].includes(i.status)))
    throw new Error('Recovery is already running; wait before starting maintenance');
  const now=Date.now();
  const window:MaintenanceWindow={host,services:[...new Set(services as string[])],startsAt:now,endsAt:now+seconds*1000,reason,silenceIds:[]};
  const scopes=services.length?window.services.map(service=>[{name:'service',value:service,isRegex:false,isEqual:true}]):[[]];
  // Multiple public services restarting can also trip the host aggregate rule.
  if(config.services.filter(s=>services.includes(s.name)&&s.publicUrl).length>1)
    scopes.push([{name:'alertname',value:'SharedPublicOutage',isRegex:false,isEqual:true}]);
  for(const scope of scopes) {
    const r=await fetch(config.alertmanagerUrl+'/api/v2/silences',{method:'POST',
      headers:{'Content-Type':'application/json'},signal:AbortSignal.timeout(5000),redirect:'error',
      body:JSON.stringify({matchers:[{name:'host',value:host,isRegex:false,isEqual:true},
        {name:'alertname',value:'MonitoringWatchdog|AIOpsPipelineCanary',isRegex:true,isEqual:false},...scope],
        startsAt:new Date(now).toISOString(),endsAt:new Date(window.endsAt).toISOString(),
        createdBy:'aiops-maintenance',comment:reason})});
    if(!r.ok) throw new Error(`Maintenance silence HTTP ${r.status}`);
    const result=JSON.parse(await boundedBody(r,10000));
    if(typeof result.silenceID!=='string') throw new Error('Invalid silence response');
    window.silenceIds.push(result.silenceID);
  }
  const windows=store.setting<MaintenanceWindow[]>('maintenance:windows',[]).filter(w=>w.endsAt>now);
  store.set('maintenance:windows',[...windows,window]);
  store.event('maintenance','started',window);
  return window;
}
