import nodemailer from 'nodemailer';
import type {Config, Incident} from './types.ts';
import type {Store} from './store.ts';
import {boundedBody, redact} from './security.ts';

export function enqueueSummary(config: Config, store: Store, i: Incident) {
  const title = `[AIOps ${i.status.replaceAll('_',' ')}] ${i.service} · ${i.host}`;
  const events = store.events(i.id);
  const actions = events.filter(e=>['action_result','action_requested'].includes(e.kind as string));
  const text = `${title}\n\nAlert: ${i.alert.summary}\n\nAssessment: ${i.diagnosis || 'Evidence gathering incomplete.'}\n\n` +
    `Recovery actions:\n${actions.length ? actions.map(e=>`${e.at} ${e.kind}: ${JSON.stringify(e.data)}`).join('\n') : 'No recovery action taken.'}\n\n` +
    `Final verification: ${JSON.stringify(i.verification || {status:'Not verified'})}\n` +
    `AI cost/reservation: $${i.spent.toFixed(4)}\nIncident: ${i.id}\n${config.publicUrl}/?incident=${i.id}`;
  for (const channel of ['pushover','email']) {
    const n = config.notification;
    if (channel === 'pushover' && !(n.pushoverToken && n.pushoverUser) ||
        channel === 'email' && !(n.smtpHost && n.emailTo)) continue;
    store.db.prepare('INSERT INTO notifications(incident,channel,data) VALUES(?,?,?)').run(i.id,channel,JSON.stringify({title,text}));
  }
  store.event(i.id,'summary',{title,text});
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
        try { await transport.sendMail({from:n.emailFrom,to:n.emailTo,subject:data.title,text:data.text,
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
