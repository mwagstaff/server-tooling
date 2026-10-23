import type {Config} from './types.ts';
import type {Store} from './store.ts';
import {fleetHealth,type HealthMonitor} from './health.ts';

// No logs, alert text, credentials or incident identifiers are exposed here.
export function metrics(config:Config,store:Store,health:HealthMonitor,now=Date.now()) {
  const lines:string[]=[];
  const emit=(name:string,value:number,service='aiops')=>
    lines.push(`${name}{service=${JSON.stringify(service)}} ${value}`);
  for(const report of fleetHealth(config.services.filter(s=>s.host===config.host),health.reports,now)) {
    emit('aiops_service_healthy',report.status==='healthy'?1:0,report.name);
    emit('aiops_service_checked_timestamp_seconds',report.checkedAt?Date.parse(report.checkedAt)/1000:0,report.name);
  }
  for(const task of ['webhook_canary','email_canary','queue_poll','reconcile'])
    emit(`aiops_${task}_timestamp_seconds`,store.setting<number>(`monitor:${task}`,0)/1000);
  emit('aiops_email_enabled',config.queue?1:0);
  const active=store.db.prepare("SELECT data FROM incidents WHERE json_extract(data,'$.status') IN ('queued','investigating','acting','verifying')").all();
  const queue=active.map(r=>JSON.parse(r.data as string)).filter(i=>
    !store.maintenance(i.host,i.service,now) && !store.setting('paused',false) && !store.setting(`paused:${i.service}`,false));
  emit('aiops_incident_oldest_seconds',queue.length?Math.max(...queue.map(i=>(now-Date.parse(i.created))/1000)):0);
  const pending=store.db.prepare('SELECT COUNT(*) AS n FROM notifications WHERE delivered=0').get();
  const failed=store.db.prepare('SELECT COUNT(*) AS n FROM notifications WHERE delivered=0 AND attempts>0').get();
  emit('aiops_notifications_pending',Number(pending?.n||0));
  emit('aiops_notifications_failed',Number(failed?.n||0));
  return lines.join('\n')+'\n';
}
