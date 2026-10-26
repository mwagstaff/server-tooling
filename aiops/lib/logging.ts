import type {Config, Incident} from './types.ts';
import {boundedBody} from './security.ts';

const names = new Set(['LogEntriesDropped','LogCollectorUnavailable','LogPipelineStalled','LogStorageSpaceLow','LogTelemetryMissing']);
export const isLoggingIncident = (i:Incident) => i.alert.source==='alertmanager' && i.service==='logging' &&
  ['mini','sky'].includes(i.host) && names.has(i.alert.name);

// The monitoring plane owns these fixed queries; alerts and models cannot supply URLs or commands.
export async function inspectLogging(config:Config, i:Incident) {
  const selector=`host=${JSON.stringify(i.host)},kind="logging"`;
  const drops=`sum by(reason) (increase(loki_process_dropped_lines_total{${selector}}[5m]) or increase(loki_write_dropped_entries_total{${selector}}[5m]))`;
  const queries:Record<string,string>={
    collectors:`up{${selector}}`,
    canaryAge:`time() - logging_canary_timestamp_seconds{${selector}}`,
    diskFree:`logging_disk_free_bytes{${selector}}`,
    dropsNow:drops, dropsAtAlert:drops
  };
  const observedAt=new Date().toISOString();
  const samples=Object.fromEntries(await Promise.all(Object.entries(queries).map(async ([name,query])=>{
    try {
      const url=new URL('/api/v1/query',config.prometheusUrl);
      url.searchParams.set('query',query);
      if(name==='dropsAtAlert') url.searchParams.set('time',i.alert.startsAt);
      const response=await fetch(url,{signal:AbortSignal.timeout(5000),redirect:'error'});
      if(!response.ok) throw new Error();
      const body=JSON.parse(await boundedBody(response,100000));
      if(body.status!=='success' || !Array.isArray(body.data?.result)) throw new Error();
      return [name,body.data.result.filter((s:any)=>Number.isFinite(Number(s.value?.[1])))];
    } catch {return [name,null];}
  })));
  const value=(name:string)=>samples[name]?.length===1 ? Number(samples[name][0].value[1]) : undefined;
  const age=value('canaryAge'), disk=value('diskFree');
  const collectors=['alloy','logs-health'].map(job=>{
    const rows=samples.collectors?.filter((s:any)=>s.metric.job===job);
    return {job,up:rows?.length===1 ? Number(rows[0].value[1])===1 : undefined};
  });
  const describeDrops=(rows:any[]|null)=> rows===null || !rows.length ? 'unavailable' :
    rows.filter(s=>Number(s.value[1])>0).map(s=>`${s.metric.reason || 'unspecified'}: approximately ${Math.round(Number(s.value[1]))}`).join(', ') || 'none observed';
  const currentDrops=samples.dropsNow?.some((s:any)=>Number(s.value[1])>0);
  const healthKnown=collectors.every(c=>c.up!==undefined) && age!==undefined && disk!==undefined && Boolean(samples.dropsNow?.length);
  const healthy=healthKnown ? collectors.every(c=>c.up) && age!>=0 && age!<=300 && disk!>=10737418240 && !currentDrops : undefined;
  const reasons=new Set((samples.dropsAtAlert || []).concat(samples.dropsNow || []).filter((s:any)=>Number(s.value[1])>0).map((s:any)=>s.metric.reason));
  let diagnosis='Logging infrastructure requires review; application availability is not determined by this alert.';
  let nextStep='Inspect collector metrics and host logs for the incident window; missing metrics must be restored before declaring logging healthy.';
  if(i.alert.name==='LogEntriesDropped') {
    diagnosis=`Collector drops in the five-minute window at alert start: ${describeDrops(samples.dropsAtAlert)}. Current five-minute window: ${describeDrops(samples.dropsNow)}.`;
    if(reasons.has('ratelimit_drop_stage')) {
      diagnosis+=' The collector rate limiter discarded excess log lines; this is log loss, not evidence of an application outage.';
      nextStep='Check Alloy stage.limit: use backpressure instead of dropping bursts, then verify ingestion delay and a complete burst test.';
    } else if(reasons.size) {
      nextStep='Inspect the named drop reasons in Alloy/Loki. Check ingestion limits, queue capacity and collector errors; do not restart applications.';
    }
  } else if(i.alert.name==='LogCollectorUnavailable') {
    diagnosis='Collector scrape checks: '+collectors.map(c=>`${c.job} ${c.up===undefined?'unknown':c.up?'up':'down'}`).join(', ')+'. This indicates monitoring reachability, not necessarily a stopped process.';
    nextStep='Check the affected collector endpoint, private metrics gateway and Tailscale connectivity; inspect the system service status.';
  } else if(i.alert.name==='LogPipelineStalled') {
    diagnosis=age===undefined ? 'No current ingestion-canary measurement is available.' : `Latest observed ingestion canary is ${Math.round(age)} seconds old; the freshness threshold is 300 seconds.`;
    nextStep='Check the canary writer, Alloy queue and authentication, Mini Loki readiness and private network connectivity.';
  } else if(i.alert.name==='LogTelemetryMissing') {
    diagnosis='Required log collector targets or telemetry are missing. Scrape availability alone does not verify log ingestion.';
    nextStep='Restore the Alloy/logs-health targets and canary/disk metrics. Check collector logs and generated monitoring configuration.';
  } else {
    diagnosis=disk===undefined ? 'No current free-space measurement is available.' : `The logging host has ${(disk/1073741824).toFixed(1)} GiB free; the alert threshold is 10 GiB.`;
    nextStep='Inspect host disk use and Loki retention/compaction. Preserve logs and investigate growth before deleting data.';
  }
  const summary=`Checks at ${observedAt}: ${collectors.map(c=>`${c.job} ${c.up===undefined?'unknown':c.up?'up':'down'}`).join(', ')}; canary age ${age===undefined?'unknown':Math.round(age)+'s'}; disk free ${disk===undefined?'unknown':(disk/1073741824).toFixed(1)+' GiB'}; dropped in last 5m: ${describeDrops(samples.dropsNow)}.`;
  return {observedAt,samples,healthy,diagnosis,nextStep,summary};
}
