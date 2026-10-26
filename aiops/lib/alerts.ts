import {createHash} from 'node:crypto';
import type {Alert, Config} from './types.ts';
import {redact} from './security.ts';

export const canonicalHost=(host:string)=>host==='ubuntu-4gb-hel1-2'?'sky':host;

// Matches monitoring/platform/config.py INCIDENT_REF so Alertmanager and AIOps notifications agree.
export const incidentRef=(id:string,startsAt:string)=>
  'INC-'+id.slice(0,8)+'-'+new Date(startsAt).toISOString().replace(/[-:]/g,'').slice(0,13)+'Z';

export const identityLabels=['check','device','instance','mountpoint','integration','reason','job'];

export const sameAlert=(a:Alert,b:Alert)=>a.source===b.source && a.host===b.host && a.service===b.service && a.name===b.name && a.startsAt===b.startsAt && identityLabels.every(k=>(a.labels[k]||'')===(b.labels[k]||''));

export function alertsFromWebhook(body: any, config: Config, now = Date.now()): Alert[] {
  if (!Array.isArray(body?.alerts) || body.alerts.length > 100) throw new Error('Expected up to 100 alerts');
  return body.alerts.filter((a: any) => !/Watchdog|^AIOpsPipelineCanary$/.test(a?.labels?.alertname || '')).map((a: any) => {
    if (!a || !a.labels || typeof a.labels !== 'object') throw new Error('Missing labels');
    const name = String(a.labels.alertname || 'Unknown').slice(0, 100);
    const starts = Date.parse(a.startsAt);
    if (!Number.isFinite(starts) || starts > now + 60000) throw new Error('Invalid alert start');
    const labels: Record<string,string> = Object.fromEntries(Object.entries(a.labels).slice(0, 30).map(([k,v]) => [k,String(v).slice(0,300)]));
    let service = labels.service || labels.service_name || labels.job || 'unknown';
    service = service.replace(/^(runtime-|app-|public-)/, '');
    const registered = config.services.find(s => s.name === service);
    // Legacy producers used Sky's OS hostname; accept only this verified alias.
    const suppliedHost = canonicalHost(labels.host);
    const host = suppliedHost || registered?.host || 'unknown';
    labels.host = host;
    if (registered && host !== registered.host) throw new Error('Service/host mismatch');
    const key = createHash('sha256').update(JSON.stringify([host, service, name, new Date(starts).toISOString(), labels.check || '', labels.device || '', labels.instance || '', ...['mountpoint','integration','reason',...(name==='LogTelemetryMissing'?['job']:[])].flatMap(k=>labels[k]?[k,labels[k]]:[])])).digest('hex');
    const startsAt=new Date(starts).toISOString();
    const fingerprint=/^[0-9a-f]{16}$/.test(a.fingerprint) ? a.fingerprint : key;
    return {source:'alertmanager', key, ref:incidentRef(fingerprint,startsAt), host, service, name,
      summary:redact(String(a.annotations?.summary || name)+(name==='TopScoresEloImportFailed'?' '+String(a.annotations?.description||''):'')).slice(0,2000),
      status:a.status === 'resolved' ? 'resolved' : 'firing', startsAt,
      labels, receivedAt:new Date(now).toISOString()};
  });
}

// Only explicit, registered aliases are mapped. Email text is never executable.
export function alertFromEmail(body: any, config: Config, now = Date.now()): Alert {
  if (typeof body?.id !== 'string' || typeof body?.text !== 'string' || body.text.length > 50000)
    throw new Error('Invalid email envelope');
  const received = Date.parse(body.receivedAt);
  if (!Number.isFinite(received) || now - received > config.staleAfterMs || received > now + 60000)
    throw new Error('Stale email');
  const text = `${body.subject || ''}\n${body.text}`;
  const matches = config.services.filter(s => new RegExp(`(?:^|[^a-z0-9-])${s.name}(?:$|[^a-z0-9-])`, 'i').test(text));
  const service = matches.length === 1 ? matches[0] : undefined;
  const weekly=/^\[(?:REVIEW|FAIL)\] (sky|mini) weekly upgrade report$/i.exec(String(body.subject||''));
  const key=createHash('sha256').update('email:' + body.id).digest('hex'), startsAt=new Date(received).toISOString();
  return {source:'email', key, ref:incidentRef(key,startsAt),
    host:weekly?.[1].toLowerCase() || service?.host || (['mini','sky'].includes(body.host)?body.host:'unknown'), service:weekly?'maintenance':service?.name || 'unknown', name:weekly?'WeeklyUpgradeReview':'EmailAlert',
    summary:redact(text).slice(0,6000), startsAt,
    status:'firing', labels:{}, receivedAt:new Date(now).toISOString()};
}
