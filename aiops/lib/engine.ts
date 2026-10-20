import type {Config, Incident, Service} from './types.ts';
import {Store} from './store.ts';
import {diagnose} from './providers.ts';
import {runTarget} from './runner.ts';
import {enqueueSummary} from './notifications.ts';
import {boundedBody, redact} from './security.ts';

const delay = (ms:number) => new Promise(r=>setTimeout(r,ms));
export class Engine {
  config: Config; store: Store; busy = false;
  run: typeof runTarget; model: typeof diagnose;
  constructor(config: Config, store: Store, run = runTarget, model = diagnose) {
    this.config=config; this.store=store; this.run=run; this.model=model;
  }
  paused(service: string) {
    return this.store.setting('paused',false) || this.store.setting(`paused:${service}`,false);
  }
  async collect(s: Service) {
    const local = await this.run(this.config,s,'inspect');
    if (local.error || !local.status) throw new Error(local.error || 'Host inspection unavailable');
    const evidence: any = {...local, logs:redact(local.logs)};
    if (s.publicUrl) {
      try {
        const r=await fetch(s.publicUrl,{signal:AbortSignal.timeout(8000),redirect:'error'});
        await r.body?.cancel();
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
        (!i.alert.labels.host || a.labels.host === i.alert.labels.host) &&
        (!i.alert.labels.instance || a.labels.instance === i.alert.labels.instance) &&
        a.startsAt && Math.abs(Date.parse(a.startsAt)-Date.parse(i.alert.startsAt))<1000);
      return matching.some((a:any)=>a.status?.state==='active') ? true : matching.length ? null : false;
    } catch {return null;}
  }
  finish(i: Incident, status:string) {
    i.status=status; this.store.put(i); enqueueSummary(this.config,this.store,i);
  }
  async tick() {
    if (this.busy) return;
    const i=this.store.list().reverse().find(i=>i.status==='queued' && !this.paused(i.service));
    if (!i) return;
    this.busy=true;
    try { await this.investigate(i); }
    catch(e) { i.diagnosis += '\n' + redact(String(e)).slice(0,1000); this.finish(i,'needs_review'); }
    finally { this.busy=false; }
  }
  async investigate(i: Incident) {
    const s=this.config.services.find(s=>s.name===i.service && s.host===i.host);
    if (!s) {
      i.diagnosis='No unambiguous registered service. Manual triage required.';
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
    this.store.event(i.id,'evidence',i.evidence);
    const firing=await this.alertStillFiring(i);
    if (i.evidence.healthy && i.evidence.public?.ok !== false && firing===false) {
      i.verification={...i.evidence,logs:undefined,alertFiring:false};
      i.diagnosis='Service and public checks are healthy; source alert has cleared without intervention.';
      return this.finish(i,i.attempts>0?'recovered':'healthy');
    }
    const actions=[...new Set([...s.autoActions,...s.approvalActions])].filter(a=>
      a!=='retry'||i.evidence.retryAvailable).filter(a=>a!=='redeploy'||i.evidence.releaseAvailable);
    if(this.store.list().filter(other=>Date.parse(other.created)>Date.now()-3600000).length>20) {
      i.diagnosis='Incident rate limit reached (20 per hour). Evidence retained; manual review required.';
      return this.finish(i,'needs_review');
    }
    const decision=await this.model(this.config,this.store,i,i.evidence,actions);
    i.diagnosis=decision.diagnosis+'\n'+decision.reason;
    i.action=decision.action;
    const latest=this.store.get(i.id);
    if(latest?.resolvedAt) {i.resolvedAt=latest.resolvedAt;return this.finish(i,'source_resolved');}
    if (decision.action==='none') {
      i.verification={healthy:i.evidence.healthy,public:i.evidence.public,alertFiring:firing};
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
