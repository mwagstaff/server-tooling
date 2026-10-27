import type {Config, Incident, Service} from './types.ts';
import {Store} from './store.ts';
import {diagnose} from './providers.ts';
import {runTarget} from './runner.ts';
import {enqueueSummary} from './notifications.ts';
import {boundedBody, redact} from './security.ts';

import {selectRunbook,maintenanceFindings} from './runbooks.ts';
import {isLoggingIncident,inspectLogging} from './logging.ts';
import {identityLabels,canonicalHost} from './alerts.ts';
import {infrastructureSpec,infrastructureOwner,inspectInfrastructure} from './infrastructure.ts';

const delay = (ms:number) => new Promise(r=>setTimeout(r,ms));
export class Engine {
  config: Config; store: Store; busy = false;
  run: typeof runTarget; model: typeof diagnose;
  constructor(config: Config, store: Store, run = runTarget, model = diagnose) {
    this.config=config; this.store=store; this.run=run; this.model=model;
  }
  paused(service: string) {
    const host=this.config.services.find(s=>s.name===service)?.host;
    return this.store.setting('paused',false) || this.store.setting(`paused:${service}`,false) || Boolean(host && this.store.maintenance(host,service));
  }
  async collect(s: Service) {
    const local = await this.run(this.config,s,'inspect');
    if (local.error || !local.status) throw new Error(local.error || 'Host inspection unavailable');
    const evidence: any = {...local, logs:redact(local.logs)};
    if (s.publicUrl) {
      try {
        const r=await fetch(s.publicUrl,{signal:AbortSignal.timeout(8000),redirect:'error'});
        await boundedBody(r,8*1024*1024);
        evidence.public={ok:r.ok,status:r.status};
      } catch { evidence.public={ok:false,error:'Public probe failed'}; }
    }
    return evidence;
  }
  async alertStillFiring(i: Incident): Promise<boolean | null> {
    if (i.alert.source !== 'alertmanager') return null;
    try {
      const response=await fetch(`${this.config.alertmanagerUrl}/api/v2/alerts`,{signal:AbortSignal.timeout(5000)});
      if (!response.ok) return null;
      const alerts=JSON.parse(await boundedBody(response,1024*1024));
      const matching=alerts.filter((a:any) => a.labels.alertname===i.alert.name &&
        (!i.alert.labels.service || a.labels.service === i.alert.labels.service) &&
        (!i.alert.labels.host || canonicalHost(a.labels.host) === canonicalHost(i.alert.labels.host)) &&
        identityLabels.every(k=>!i.alert.labels[k] || a.labels[k]===i.alert.labels[k]) &&
        a.startsAt && Math.abs(Date.parse(a.startsAt)-Date.parse(i.alert.startsAt))<1000);
      return matching.some((a:any)=>a.status?.state==='active') ? true : matching.length ? null : false;
    } catch {return null;}
  }
  finish(i: Incident, status:string) {
    if(this.store.maintenance(i.host,i.service)) {
      i.status='queued';this.store.put(i);this.store.set(`maintenance:deferred:${i.id}`,true);return;
    }
    i.status=status; this.store.put(i); enqueueSummary(this.config,this.store,i);
  }
  async tick() {
    if (this.busy) return;
    for(const incident of this.store.list().filter(i=>i.status==='queued' && this.store.maintenance(i.host,i.service)))
      this.store.set(`maintenance:deferred:${incident.id}`,true);
    const i=this.store.list().reverse().find(i=>i.status==='queued' && !this.paused(i.service) && !this.store.maintenance(i.host,i.service));
    if (!i) return;
    this.busy=true;
    try { await this.investigate(i); }
    catch(e) { i.diagnosis += '\n' + redact(String(e)).slice(0,1000); this.finish(i,'needs_review'); }
    finally { this.busy=false; }
  }
  async investigate(i: Incident) {
    const runbook=selectRunbook(i);i.runbook={id:runbook.id,version:runbook.version};
    this.store.event(i.id,'runbook',runbook);this.store.put(i);
    if(['MonitoringNotificationFailures','AIOpsReconciliationStalled'].includes(i.alert.name)) {
      const candidates=this.store.list().map(x=>({id:x.id,host:x.host,name:x.alert.name,startsAt:x.alert.startsAt,url:this.config.publicUrl+'/?incident='+x.id}));
      if(this.config.peerToken)for(const base of Object.values(this.config.peers))try {
        const r=await fetch(base+'/api/related-incidents',{headers:{Authorization:'Bearer '+this.config.peerToken},signal:AbortSignal.timeout(5000),redirect:'error'});
        if(r.ok)candidates.push(...JSON.parse(await boundedBody(r,100000)).incidents);
      }catch{}
      i.related=candidates.filter(x=>x.id!==i.id && x.host===i.host && ['MonitoringNotificationFailures','AIOpsReconciliationStalled'].includes(x.name) && Math.abs(Date.parse(x.startsAt)-Date.parse(i.alert.startsAt))<=600000).slice(0,10).map(({id,name,url})=>({id,name,url}));
      this.store.put(i);
    }
    if(i.alert.name==='WeeklyUpgradeReview') {
      i.action='none';i.evidence={reportedFindings:maintenanceFindings(i.alert.summary)};
      i.diagnosis=i.evidence.reportedFindings.join(' ');i.verification={healthy:null,alertFiring:null};
      return this.finish(i,'needs_review');
    }
    if(i.alert.name==='TopScoresEloImportFailed') {
      const service=this.config.services.find(s=>s.name===i.service && s.host===i.host);
      if(!service || service.owner!==this.config.host)return this.finish(i,'other_host');
      i.action='none';i.evidence=await this.collect(service);
      const reported=/Last dataset update: (\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d\d:\d\d))/.exec(i.alert.summary)?.[1];
      const age=reported?Date.now()-Date.parse(reported):NaN;
      i.evidence.reportedDatasetAgeHours=Number.isFinite(age)&&age>=0?Math.round(age/360000)/10:null;
      i.diagnosis='Upstream import failure. '+i.alert.summary+' '+(i.evidence.reportedDatasetAgeHours!==null?'Reported dataset age: '+i.evidence.reportedDatasetAgeHours+' hours. ':'Dataset age unavailable. ')+
        'Retain the last validated dataset. Leave retries to the bounded importer schedule; do not restart the application or bypass upstream access controls.';
      i.verification={healthy:i.evidence.healthy,alertFiring:await this.alertStillFiring(i)};
      this.store.event(i.id,'evidence',i.evidence);
      return this.finish(i,i.verification.alertFiring===false?'source_resolved':'needs_review');
    }
    if(isLoggingIncident(i) || infrastructureSpec(i)) {
      const isLogging=isLoggingIncident(i);
      const owner=isLogging ? (i.host==='sky'?'mini':'sky') : infrastructureOwner(i);
      if(owner!==this.config.host) {i.diagnosis=`Infrastructure incident belongs to ${owner}.`;return this.finish(i,'other_host');}
      if(Date.now()-Date.parse(i.alert.receivedAt)>this.config.staleAfterMs) {
        i.diagnosis='Infrastructure alert is stale; fresh evidence is required.';return this.finish(i,'stale');
      }
      i.status='investigating';this.store.put(i);
      const logging=isLogging ? await inspectLogging(this.config,i) : await inspectInfrastructure(this.config,i);
      i.evidence=isLogging ? {logging} : {infrastructure:logging};i.diagnosis=logging.diagnosis;i.action='none';
      i.verification={healthy:logging.healthy,alertFiring:await this.alertStillFiring(i)};
      this.store.event(i.id,'evidence',i.evidence);
      const latest=this.store.get(i.id);if(latest?.resolvedAt)i.resolvedAt=latest.resolvedAt;
      return this.finish(i,logging.healthy===true && i.verification.alertFiring===false?'healthy':'needs_review');
    }
    const s=this.config.services.find(s=>s.name===i.service && s.host===i.host);
    if (!s) {
      i.diagnosis='No registered application or supported infrastructure investigation matches this alert. Source state is checked; the underlying cause still requires review.';
      i.verification={alertFiring:await this.alertStillFiring(i)};
      if (this.config.ssh[i.host]) {
        try {i.evidence=await this.run(this.config,{host:i.host,name:'__host__'},'inspect');} catch {}
      }
      return this.finish(i,'needs_review');
    }
    if (s.owner!==this.config.host) {
      i.diagnosis=`Incident belongs to ${s.owner}; no recovery is permitted from this host.`;
      return this.finish(i,'other_host');
    }
    if (Date.now()-Date.parse(i.alert.receivedAt)>this.config.staleAfterMs) {
      i.diagnosis='Alert was queued too long. Fresh alert evidence is required.';
      return this.finish(i,'stale');
    }
    i.status='investigating';this.store.put(i);
    try {i.evidence=await this.collect(s);}
    catch(e) {i.diagnosis='Cannot reach the host or inspect this service. '+redact(String(e));return this.finish(i,'unreachable');}
    // Fixed, read-only queries: model output never controls a query or URL.
    const selector = `service=${JSON.stringify(s.name)},host=${JSON.stringify(s.host)}`;
    const queries: Record<string,string> = {
      restarts15m:`changes(monitoring_process_start_time_seconds{${selector}}[15m])`,
      errors5m:`monitoring:http_error_ratio5m{${selector}}`,
      responses5m:`sum by(status) (increase(monitoring_http_requests_total{${selector}}[5m]))`
    };
    i.evidence.metrics = Object.fromEntries(await Promise.all(Object.entries(queries).map(async ([name,query])=>{
      try {
        const url=new URL('/api/v1/query',this.config.prometheusUrl);url.searchParams.set('query',query);
        const response=await fetch(url,{signal:AbortSignal.timeout(5000),redirect:'error'});
        if(!response.ok) throw new Error('Metrics unavailable');
        const body=JSON.parse(await boundedBody(response,100000));
        if(body.status!=='success' || !Array.isArray(body.data?.result)) throw new Error('Invalid metrics');
        return [name,{observedAt:new Date().toISOString(),samples:body.data.result}];
      } catch { return [name,{error:'Metrics unavailable; do not infer zero'}]; }
    })));
    if(this.config.logs) {
      try {
        const url=new URL('/loki/api/v1/query_range',this.config.logs.url);
        url.search=new URLSearchParams({query:`{host=${JSON.stringify(i.host)},service=${JSON.stringify(i.service)}}`,
          start:String((Date.parse(i.alert.startsAt)-15*60000)*1e6),end:String(Date.now()*1e6),limit:'100',direction:'backward'}).toString();
        const response=await fetch(url,{headers:{Authorization:'Basic '+Buffer.from('logs:'+this.config.logs.token).toString('base64')},
          signal:AbortSignal.timeout(8000),redirect:'error'});
        if(!response.ok) throw new Error('Log query unavailable');
        const body=JSON.parse(await boundedBody(response,256*1024));
        i.evidence.recentLogs=(body.data?.result || []).flatMap((stream:any)=>stream.values.map((v:any)=>({
          at:new Date(Number(v[0])/1e6).toISOString(),source:stream.stream.source,
          timestampSource:stream.stream.timestamp_source,line:redact(v[1]).slice(0,500)}))).sort((a:any,b:any)=>b.at.localeCompare(a.at)).slice(0,30);
      } catch { i.evidence.logQueryError='Time-filtered logs unavailable.'; }
    }
    const metadata=Object.values(i.evidence.logMetadata || {}) as any[];
    i.evidence.qualityIssues=[];
    i.evidence.eventLogs=(i.evidence.eventLogs || []).filter((l:any)=>Date.parse(l.at)>=Date.parse(i.alert.startsAt)-15*60000 && Date.parse(l.at)<=Date.now());
    if(!i.evidence.eventLogs.length && !i.evidence.recentLogs?.some((l:any)=>l.timestampSource==='journal') && (!metadata.length || metadata.every(m=>!m.timestamped)))
      i.evidence.qualityIssues.push('Application log lines lack verified event timestamps; they cannot establish the current cause.');
    for(const [name,m] of Object.entries(i.evidence.logMetadata || {}) as [string,any][]) {
      if(Date.parse(m.modifiedAt)<Date.parse(i.alert.startsAt)-15*60000) {
        // collect() serializes/redacts the tail; drop it when any component is stale.
        i.evidence.logs='Historical log tails omitted; use time-filtered recentLogs.';
      }
    }
    if(metadata.some(m=>Date.parse(m.modifiedAt)<Date.parse(i.alert.startsAt)-15*60000))
      i.evidence.qualityIssues.push('Some log files predate the incident window.');
    if(Object.values(i.evidence.metrics).some((m:any)=>m.error || !m.samples?.length))
      i.evidence.qualityIssues.push('Some current metrics are missing.');
    this.store.event(i.id,'evidence',i.evidence);
    const firing=await this.alertStillFiring(i);
    if (i.evidence.healthy && i.evidence.public?.ok !== false && firing===false) {
      i.verification={...i.evidence,logs:undefined,alertFiring:false};
      i.diagnosis='Service and public checks are healthy; source alert has cleared without intervention.';
      if(this.store.setting(`maintenance:deferred:${i.id}`,false) && !i.attempts) {i.status='healthy';this.store.put(i);return;}
      return this.finish(i,i.attempts>0?'recovered':'healthy');
    }
    if(this.store.maintenance(i.host,i.service)) return this.finish(i,'queued');
    if(this.store.setting(`maintenance:deferred:${i.id}`,false) && i.evidence.healthy && i.evidence.public?.ok!==false &&
       (i.alert.source==='email'||firing===false)) {
      i.diagnosis='Healthy after planned maintenance; no investigation or recovery needed.';
      i.status='healthy';this.store.put(i);this.store.event(i.id,'maintenance_cleared',{});return;
    }
    const actions=[...new Set([...s.autoActions,...s.approvalActions])].filter(a=>
      a!=='retry'||i.evidence.retryAvailable).filter(a=>a!=='redeploy'||i.evidence.releaseAvailable).filter(a=>runbook.allowedActions.includes(a));
    if(this.store.list().filter(other=>Date.parse(other.created)>Date.now()-3600000).length>20) {
      i.diagnosis='Incident rate limit reached (20 per hour). Evidence retained; manual review required.';
      return this.finish(i,'needs_review');
    }
    const decision=await this.model(this.config,this.store,i,i.evidence,actions);
    i.diagnosis=decision.diagnosis+'\n'+decision.reason;
    i.action=decision.action;
    const finalFiring=await this.alertStillFiring(i);
    i.verification={healthy:i.evidence.healthy,public:i.evidence.public,alertFiring:finalFiring};
    const latest=this.store.get(i.id);
    if(latest?.resolvedAt) {i.resolvedAt=latest.resolvedAt;return this.finish(i,'source_resolved');}
    if (decision.action==='none') {
      i.verification={healthy:i.evidence.healthy,public:i.evidence.public,alertFiring:finalFiring};
      return this.finish(i,'needs_review');
    }
    if (!actions.includes(decision.action)) {
      i.diagnosis+='\nProposed action is not registered for this service.';
      return this.finish(i,'needs_review');
    }
    // Even a valid tool selection needs observed failure and independent policy.
    const auto=this.store.setting('automatic',this.config.automatic) &&
      s.autoActions.includes(decision.action) && decision.confidence==='high' &&
      !i.evidence.healthy && (i.alert.source!=='alertmanager'||firing===true) &&
      !/RestartLoop|Disk|Oom|MemoryPressure|SharedPublicOutage|Certificate/.test(i.alert.name);
    if (!auto) {
      i.approvalExpires=new Date(Date.now()+30*60000).toISOString();
      return this.finish(i,'needs_approval');
    }
    await this.execute(i,s,false);
  }
  async approve(id:string, action:string) {
    if(this.busy) throw new Error('Another investigation is running; retry shortly');
    const i=this.store.get(id);
    if(!i || i.status!=='needs_approval' || i.action!==action || Date.parse(i.approvalExpires||'')<Date.now())
      throw new Error('Approval is unavailable or expired');
    const s=this.config.services.find(s=>s.name===i.service && s.host===i.host);
    if(!s || s.owner!==this.config.host || this.paused(s.name)) throw new Error('Service unavailable or paused');
    this.busy=true;
    this.store.event(i.id,'approved',{action,service:s.name});
    try {await this.execute(i,s,true);}
    catch(e) {i.diagnosis+='\n'+redact(String(e));this.finish(i,'needs_review');}
    finally {this.busy=false;}
  }
  async execute(i:Incident,s:Service,approved:boolean) {
    if(this.paused(s.name)) {i.diagnosis+='\nRecovery paused before execution.';return this.finish(i,'paused');}
    if(i.attempts>=this.config.maxActions) {i.diagnosis+='\nAction limit reached.';return this.finish(i,'needs_review');}
    const fresh=await this.collect(s);
    const firing=await this.alertStillFiring(i);
    if(!approved && (fresh.healthy || i.alert.source==='alertmanager' && firing!==true))
      return this.finish(i,'needs_review');
    // Re-read control state after network calls and before any mutation.
    if(this.paused(s.name)) return this.finish(i,'paused');
    if(this.store.get(i.id)?.resolvedAt) return this.finish(i,'source_resolved');
    i.status='acting';i.attempts++;this.store.put(i);
    const actionId=`${i.id}_${i.attempts}`;
    this.store.event(i.id,'action_requested',{action:i.action,actionId,approved,service:s.name});
    const result=await this.run(this.config,s,i.action!,{actionId,approved,allowHealthy:approved});
    this.store.event(i.id,'action_result',result);
    i.status='verifying';this.store.put(i);
    const samples=[];
    for(let n=0;n<3;n++) {
      await delay(this.config.verifyDelayMs);
      try {
        const sample=await this.collect(s);
        samples.push({at:new Date().toISOString(),healthy:sample.healthy,public:sample.public});
      } catch {samples.push({at:new Date().toISOString(),healthy:false,unreachable:true});}
    }
    const stillFiring=await this.alertStillFiring(i);
    i.verification={samples,alertFiring:stillFiring,actionSucceeded:result.ok===true};
    this.store.event(i.id,'verification',i.verification);
    const healthy=samples.every(s=>s.healthy && s.public?.ok!==false);
    this.finish(i,healthy ? (stillFiring===true ? 'improved' : stillFiring===null && i.alert.source==='alertmanager' ? 'verification_incomplete' :
      result.ok ? 'recovered' : 'healthy') : 'still_failing');
  }
}
