import {incidentBudget} from './budget.ts';
import nodemailer from 'nodemailer';
import type {Config, Incident} from './types.ts';
import type {Store} from './store.ts';
import {boundedBody, redact} from './security.ts';

// Explicit block elements survive mail gateways that collapse plain-text newlines.
export function summaryHtml(text: string): string {
  const escape = (value:string) => value.replaceAll('&','&amp;').replaceAll('<','&lt;')
    .replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
  const items = text.split(/\r?\n/).filter(line=>line.trim()).map(line=>{
    const content=line.replace(/^- /,'');
    const colon=content.indexOf(':');
    const label=colon<0 ? '' : `<strong>${escape(content.slice(0,colon+1))}</strong> `;
    const value=colon<0 ? content : content.slice(colon+1).trim();
    const linked = ['Incident','Service metrics','Host metrics','Logs'].includes(content.slice(0,colon));
    const body=linked && /^https?:\/\//.test(value)
      ? `<a href="${escape(value)}">${content.startsWith('Incident:') ? 'Open incident console' : 'Open dashboard'}</a>` : escape(value);
    return `<li style="margin:0 0 12px;padding-left:4px;">${label}${body}</li>`;
  }).join('\n');
  return `<html><body><div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.6;max-width:720px;">` +
    `<ul style="margin:0;padding-left:24px;">${items}</ul></div></body></html>`;
}

export function enqueueSummary(config: Config, store: Store, i: Incident) {
  const current = store.get(i.id) || i;
  if(current.resolvedAt && (store.setting('summary:resolved:'+i.id,false) || store.events(i.id).some(e=>e.kind==='summary' && e.data.title?.startsWith('[AIOps SOURCE CLEARED]')))) {
    store.set('summary:resolved:'+i.id,true);return;
  }
  const v = current.verification;
  const status = current.resolvedAt || v?.alertFiring === false ? 'SOURCE CLEARED' :
    ['healthy','recovered'].includes(current.status) ? 'HEALTHY' :
    current.status === 'still_failing' ? 'STILL FAILING' :
    current.status === 'needs_approval' ? 'APPROVAL NEEDED' : 'REVIEW NEEDED';
  const compact = (value: string, max = 600) => {
    const text=redact(value).replace(/\s+/g,' ').trim();
    if(text.length<=max) return text;
    const sentences=text.slice(0,max).match(/^.*[.!?](?=\s)/);
    return (sentences?.[0] || 'Assessment requires the full incident record.') + ' See incident for details.';
  };
  const title = `[AIOps ${status}] ${i.service} · ${i.host} · ${i.alert.name}`;
  const events = store.events(i.id);
  const actions = events.filter(e=>e.kind === 'action_requested');
  const samples = v?.samples;
  const healthy = samples?.length ? samples.every((s:any)=>s.healthy && s.public?.ok !== false) : v?.healthy;
  const infrastructure=i.evidence?.infrastructure;
  const logging=i.evidence?.logging || infrastructure;
  const checks = healthy === true ? 'Last service checks passed' : healthy === false ? 'Last service checks failed' : 'Service health not verified';
  const source = current.resolvedAt ? `cleared at ${current.resolvedAt}` :
    v?.alertFiring === false ? 'cleared' : v?.alertFiring === true ? 'firing at last check' : 'unknown';
  const metrics=i.evidence?.metrics;
  const scalar=(name:string) => { const v=metrics?.[name]?.samples?.[0]?.value?.[1]; return v!==undefined && Number.isFinite(Number(v)) ? Number(v) : undefined; };
  const ratio=scalar('errors5m');
  const responses=metrics?.responses5m?.samples;
  const counts=Array.isArray(responses) && responses.length ? responses.filter((s:any)=>Number(s.value?.[1])>0).map((s:any)=>`${s.metric.status}: approximately ${Math.round(Number(s.value[1]))}`).join(', ') : 'unavailable';
  const grafana=new URL(config.publicUrl);grafana.port='13000';grafana.pathname='/';grafana.search='';
  const from=Date.parse(i.alert.startsAt)-15*60000;
  const to=Math.max(Date.parse(current.resolvedAt || current.updated),Date.parse(i.alert.startsAt))+5*60000;
  const dashboard=(uid:string)=>`${grafana.origin}/d/${uid}?${new URLSearchParams({'var-host':i.host,'var-service':i.service,from:String(from),to:String(to)})}`;
  const text = [
    `- Summary: ${status}. ${logging ? checks.replace('Service',infrastructure?'Infrastructure':'Logging').replace('service',infrastructure?'infrastructure':'logging') : checks}; source alert ${source}. Workflow: ${current.status.replaceAll('_',' ')}.`,
    `- Alert: ${i.alert.name} — ${compact(i.alert.summary,200)}`,
    ...(logging ? [`- Evidence: ${logging.summary}`] : []),
    ...(metrics ? [`- Evidence: Five-minute window at ${metrics.responses5m?.observedAt || 'unknown time'}; combined 5xx/abort ratio ${ratio===undefined ? 'unavailable' : (ratio*100).toFixed(2)+'%'}; responses ${counts}; restarts in 15 minutes: ${scalar('restarts15m') ?? 'unknown'}.`] : []),
    ...(i.evidence?.qualityIssues?.length ? [`- Evidence gaps: ${i.evidence.qualityIssues.join(' ')}`] : []),
    ...(i.runbook ? [`- Runbook: ${i.runbook.id} v${i.runbook.version}`] : []),
    ...(i.related?.length ? [`- Related incidents: Possible shared cause; ${i.related.map(r=>r.name+' '+r.url).join('; ')}`] : []),
    `- Assessment: ${compact(i.diagnosis || 'Evidence gathering incomplete.')}`,
    `- Actions: ${actions.length ? actions.map(e=>compact(String(e.data.action),40)).join(', ') + '; see incident for outcomes.' : 'No recovery action taken.'}`,
    `- Next step: ${logging ? (healthy===true && source.startsWith('cleared') ? 'Infrastructure checks passed and the source cleared; retain the incident evidence for review.' : logging.nextStep) : current.status === 'needs_approval' && !current.resolvedAt ? 'Review the proposed action in the console.' : healthy === true && source.startsWith('cleared') ? 'No immediate recovery needed; review any remaining cause uncertainty.' : 'Review the evidence and unresolved cause in the console.'}`,
    `- AI cost/reservation: $${i.spent.toFixed(4)} of $${incidentBudget(config,store).toFixed(2)} incident allowance.`,
    `- Incident: ${config.publicUrl}/?incident=${i.id}`,
    `- Service metrics: ${dashboard(infrastructure?.dashboard || (logging?'monitoring-logging':'monitoring-service'))}`,
    `- Host metrics: ${dashboard('monitoring-host')}`,
    `- Logs: ${logging ? dashboard('monitoring-logs').replace(/var-service=[^&]*/, 'var-service=.%2A') : dashboard('monitoring-logs')}`
  ].join('\n');
  for (const channel of ['pushover','email']) {
    const n = config.notification;
    if (channel === 'pushover' && !(n.pushoverToken && n.pushoverUser) ||
        channel === 'email' && !(n.smtpHost && n.emailTo)) continue;
    store.db.prepare('INSERT INTO notifications(incident,channel,data) VALUES(?,?,?)').run(i.id,channel,JSON.stringify({title,text}));
  }
  store.event(i.id,'summary',{title,text});
  if(current.resolvedAt)store.set('summary:resolved:'+i.id,true);
}

export async function flushNotifications(config: Config, store: Store) {
  const rows = store.db.prepare('SELECT * FROM notifications WHERE delivered=0 AND attempts<8 AND next<? LIMIT 5').all(Date.now());
  for (const row of rows) {
    const data = JSON.parse(row.data as string), n = config.notification;
    try {
      if (row.channel === 'pushover') {
        const response = await fetch('https://api.pushover.net/1/messages.json',{
          method:'POST',body:new URLSearchParams({token:n.pushoverToken!,user:n.pushoverUser!,
            title:data.title.slice(0,250),message:data.text.slice(0,1000),url:config.publicUrl,
            url_title:'Open incident console',priority:'0'}),signal:AbortSignal.timeout(15000)
        });
        const result = JSON.parse(await boundedBody(response,10000));
        if (!response.ok || result.status !== 1) throw new Error(`Pushover HTTP ${response.status}`);
      } else {
        const transport = nodemailer.createTransport({host:n.smtpHost,port:n.smtpPort || 587,
          secure:n.smtpPort === 465,requireTLS:true,
          auth:{user:n.smtpUser,pass:n.smtpPassword},connectionTimeout:10000,socketTimeout:15000});
        try { await transport.sendMail({from:n.emailFrom,to:n.emailTo,subject:data.title,text:data.text,html:summaryHtml(data.text),
          headers:{'X-AIOps-Summary':'true','Auto-Submitted':'auto-generated'}}); }
        finally { transport.close(); }
      }
      store.db.prepare('UPDATE notifications SET delivered=1 WHERE id=?').run(row.id);
      store.event(row.incident as string,'notification_delivered',{channel:row.channel});
    } catch(e) {
      store.db.prepare('UPDATE notifications SET attempts=attempts+1,next=? WHERE id=?')
        .run(Date.now() + Math.min(3600000, 30000 * 2 ** Number(row.attempts)),row.id);
      store.event(row.incident as string,'notification_failed',{channel:row.channel,error:redact(String(e)).slice(0,200)});
    }
  }
}
