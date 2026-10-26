import type {Config,Incident} from './types.ts';
import {boundedBody,redact} from './security.ts';

type Spec={family:'host'|'monitor'|'aiops'|'connectivity';query:string;next:string;local?:boolean};
const specs:Record<string,Spec>={};
const add=(names:string[],family:Spec['family'],query:string,next:string,local=false)=>{
  for(const name of names)specs[name]={family,query,next,local};
};
add(['MonitoringNotificationFailures'],'monitor','increase(alertmanager_notifications_failed_total{host="$host"}[2m])',
  'Inspect the failing integration/reason and Alertmanager retry logs. Compare recent failures with successful attempts; a successful retry is not proof of inbox receipt.',true);
add(['MonitoringRuleFailures'],'monitor','increase(prometheus_rule_evaluation_failures_total{host="$host"}[2m])',
  'Inspect Prometheus rule health and lastError, then validate the affected expression and data source.',true);
add(['MonitoringComponentUnavailable'],'monitor','up{kind="monitor",host="$host"}',
  'Check the named monitoring component, its listener and system service; preserve monitoring state.',true);
add(['MetricsAccessUnavailable'],'host','up{kind="host",host="$host"}',
  'Check the private metrics gateway, node exporter and Tailscale connectivity before assuming the host is down.');
add(['HostCpuPressure'],'host','1 - avg by(host) (rate(node_cpu_seconds_total{host="$host",mode="idle"}[5m]))',
  'Inspect processes and recent scheduled jobs; CPU fraction above 0.90 for 15 minutes triggers this alert.');
add(['HostMemoryPressure'],'host','node_memory_MemAvailable_bytes{host="$host"} / node_memory_MemTotal_bytes{host="$host"}',
  'Inspect memory consumers and swap; available memory below 0.10 for 10 minutes triggers this alert.');
add(['MacMemoryPressure'],'host','(node_memory_free_bytes{host="$host"} + node_memory_inactive_bytes{host="$host"}) / node_memory_total_bytes{host="$host"}',
  'Inspect memory pressure and swap-out rate together; low reclaimable memory alone does not establish thrashing.');
add(['HostIoPressure'],'host','avg by(host) (rate(node_cpu_seconds_total{host="$host",mode="iowait"}[5m]))',
  'Inspect disk latency and active I/O jobs; I/O wait above 0.20 for 10 minutes triggers this alert.');
add(['HostOomKill'],'host','increase(node_vmstat_oom_kill{host="$host"}[10m])',
  'Inspect kernel logs to identify the killed process and its memory use; do not restart unrelated applications.');
add(['DiskSpaceLow','DiskSpaceCritical'],'host','node_filesystem_avail_bytes{host="$host",fstype!~"tmpfs|overlay|squashfs|devtmpfs"} / node_filesystem_size_bytes{host="$host"}',
  'Inspect the affected mountpoint and growth. Warning is below 15% free, critical below 5%; preserve data before any cleanup.');
add(['DiskWillFill'],'host','predict_linear(node_filesystem_avail_bytes{host="$host",fstype!~"tmpfs|overlay|squashfs|devtmpfs"}[6h],86400)',
  'Review the six-hour growth trend and predicted free bytes in 24 hours; a negative prediction is not a full disk now.');
add(['HighLoad'],'host','node_load5{host="$host"}',
  'Inspect runnable processes and I/O waits; load above 8 for 15 minutes triggers this Mini alert.');
add(['SharedPublicOutage'],'host','probe_success{kind="public",host="$host"}',
  'Inspect the failed public probes, shared proxy/tunnel and network before considering application recovery.');
add(['PingDown','DnsDown','OutboundHttpsDown'],'connectivity','probe_success{kind="auxiliary",host="$host"}',
  'Compare DNS, ICMP and HTTPS probes. Inspect the router, outbound route and probe exporter; one failed probe does not prove every Internet path is down.',true);
add(['AuxiliaryCollectorUnavailable'],'connectivity','up{kind="auxiliary",host="$host"}',
  'Inspect the named auxiliary collector and its listener; failed collection is not proof the underlying network check failed.',true);
add(['MacSleptRecently'],'connectivity','mac_sleep_events_24h{host="$host"}',
  'Review sleep/wake history. This is a count over the last 24 hours, not a claim that the Mac is currently asleep.',true);
add(['SleepSettingReverted'],'connectivity','mac_pmset_setting{host="$host",name="sleep"}',
  'Review the Mini power settings and recent changes. Expected idle sleep setting is 0.',true);
add(['AIOpsUnavailable','AIOpsTargetMissing','AIOpsTelemetryMissing'],'aiops','up{kind="aiops",host="$host"}',
  'Check the peer responder, private metrics route and required telemetry. Missing target or metrics must not be treated as healthy.');
for(const [name,metric,threshold] of [
  ['AIOpsWebhookStalled','webhook_canary',180],['AIOpsEmailIntakeStalled','queue_poll',120],
  ['AIOpsEmailCanaryMissing','email_canary',900],['AIOpsReconciliationStalled','reconcile',180]
] as const)add([name],'aiops',`time() - aiops_${metric}_timestamp_seconds{host="$host"}`,
  `Inspect the ${metric} stage on the peer responder; age above ${threshold} seconds triggers the condition. Check upstream delivery/authentication and responder logs.`);
add(['AIOpsProcessingStalled'],'aiops','aiops_incident_oldest_seconds{host="$host"}',
  'Inspect queued/in-progress incidents, provider timeouts and responder errors; never replay a recovery action without checking its action journal.');
add(['AIOpsNotificationFailures'],'aiops','aiops_notifications_failed{host="$host"}',
  'Inspect failed email/Pushover outbox entries, retry attempts and authentication. Exhausted deliveries require explicit review.');
add(['AIOpsNotificationBacklog'],'aiops','aiops_notifications_pending{host="$host"}',
  'Inspect pending email/Pushover outbox entries and their next retry times; distinguish transient retry from exhausted delivery.');

specs.AIOpsTelemetryMissing.query=['webhook_canary_timestamp_seconds','reconcile_timestamp_seconds','queue_poll_timestamp_seconds','email_canary_timestamp_seconds','email_enabled','incident_oldest_seconds','notifications_pending','notifications_failed']
  .map(name=>`label_replace(absent(aiops_${name}{host="$host"}), "missing_metric", "aiops_${name}", "", "")`).join(' or ');

export const infrastructureNames=Object.keys(specs);
export function infrastructureSpec(i:Incident) {
  if(i.alert.source!=='alertmanager' || !['mini','sky'].includes(i.host))return undefined;
  // Explicit infrastructure names only; registered application checks keep their existing policy.
  return specs[i.alert.name];
}
export function infrastructureOwner(i:Incident) {
  return specs[i.alert.name]?.local ? i.host : i.host==='mini'?'sky':'mini';
}
export async function inspectInfrastructure(config:Config,i:Incident) {
  const spec=specs[i.alert.name];
  const base=spec.query.replaceAll('$host',i.host);
  const queries:Record<string,{query:string;time?:string}>={current:{query:base},atAlert:{query:base,time:i.alert.startsAt}};
  if(i.alert.name==='MonitoringNotificationFailures') {
    queries.atAlert.query=base.replace('[2m]','[10m]');
    queries.attempts={query:`increase(alertmanager_notifications_total{host="${i.host}"}[2m])`};
    queries.target={query:`up{host="${i.host}",job="alertmanager"}`};
  }
  const samples=Object.fromEntries(await Promise.all(Object.entries(queries).map(async([name,q])=>{
    try {
      const url=new URL('/api/v1/query',config.prometheusUrl);url.searchParams.set('query',q.query);
      if(q.time)url.searchParams.set('time',q.time);
      const response=await fetch(url,{signal:AbortSignal.timeout(5000),redirect:'error'});
      if(!response.ok)throw new Error();
      const body=JSON.parse(await boundedBody(response,150000));
      if(body.status!=='success'||!Array.isArray(body.data?.result))throw new Error();
      return [name,body.data.result.filter((s:any)=>s.value?.[1]!==undefined && Number.isFinite(Number(s.value[1])))];
    }catch{return [name,null];}
  })));
  const describe=(rows:any[]|null,positive=false)=>{
    if(!rows?.length)return 'unavailable (missing data is not zero)';
    const selected=positive?rows.filter(s=>Number(s.value[1])>0):rows;
    if(!selected.length)return 'none observed';
    return selected.slice(0,10).map(s=>{
      const labels=Object.entries(s.metric).filter(([k])=>['integration','reason','job','check','device','mountpoint','service','instance','missing_metric'].includes(k));
      return `${labels.map(([k,v])=>`${k}=${redact(String(v)).slice(0,120)}`).join(' ') || i.host}: ${Number(s.value[1]).toFixed(3)}`;
    }).join('; ')+(selected.length>10?`; ${selected.length-10} additional series in incident evidence`:'');
  };
  const observedAt=new Date().toISOString();
  let healthy:boolean|undefined;
  let diagnosis=`${i.alert.name}: current metric evidence ${describe(samples.current)}. At alert start: ${describe(samples.atAlert)}. These measurements describe the symptom; they do not establish a root cause.`;
  if(i.alert.name==='MonitoringNotificationFailures') {
    const current=samples.current,attempts=samples.attempts,target=samples.target;
    const total=(rows:any[])=>rows.reduce((n,s)=>n+Number(s.value[1]),0);
    // Only claim success when the integration that originally failed has new successes.
    const affected=new Set((samples.atAlert||[]).filter((s:any)=>Number(s.value[1])>0).map((s:any)=>s.metric.integration));
    const recovered=affected.size>0 && [...affected].every(integration=>{
      const sent=attempts?.filter((s:any)=>s.metric.integration===integration);
      const failed=current?.filter((s:any)=>s.metric.integration===integration);
      return sent?.length && failed?.length && total(sent)>total(failed) && total(failed)===0;
    });
    if(current?.length && target?.length===1)healthy=Number(target[0].value[1])===1 && recovered;
    diagnosis=`Notification failures in the 10-minute window at alert start: ${describe(samples.atAlert,true)}. Failures in the last 2 minutes: ${describe(current,true)}. `+
      (recovered?'The affected integration has subsequent successful notification attempts; delivery has resumed.':'Recovery is not yet verified for every affected integration.')+
      ' A webhook failure is not an SMTP failure; successful attempts do not prove device/inbox receipt.';
  }
  const summary=`Observed ${observedAt}. Current measurements: ${describe(samples.current,i.alert.name==='MonitoringNotificationFailures')}.`;
  return {observedAt,samples,healthy,diagnosis,summary,nextStep:spec.next,
    dashboard:spec.family==='host'?'monitoring-host':'monitoring-monitor',family:spec.family};
}
