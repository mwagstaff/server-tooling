import PostalMime from 'postal-mime';

export function emailHost(subject) {
  const matches=['mini','sky'].filter(h=>new RegExp(`(?:monitoring-|\\b)${h}\\b`,'i').test(subject));
  return matches.length===1?matches[0]:undefined;
}

export function routeEmail(subject, text, miniServices) {
  const content=`${subject}\n${text}`.toLowerCase();
  const mentionsMini=miniServices.split(',').some(s=>s && new RegExp(`(?:^|[^a-z0-9-])${s.trim()}(?:$|[^a-z0-9-])`).test(content));
  // Sky is responsible for Mini services; Mini handles Sky and unknown triage.
  return mentionsMini || emailHost(subject)==='mini'?'SKY_QUEUE':'MINI_QUEUE';
}

export default {
  async scheduled(_event, env) {
    const canary={type:'aiops-queue-canary',sentAt:new Date().toISOString()};
    await Promise.all([env.MINI_QUEUE.send(canary),env.SKY_QUEUE.send(canary)]);
  },
  async email(message, env) {
    if(message.to.toLowerCase()!==env.ALERT_ADDRESS.toLowerCase()) {
      message.setReject('Unknown alert recipient');return;
    }
    // Cloudflare's receiving MTA supplies the first authentication result. Do not
    // trust an appended result supplied by a sender. Plunk/SES uses a different
    // envelope return address, so authorisation follows the DMARC-aligned From.
    const allowed=env.ALLOWED_SENDERS.split(',').map(s=>s.trim().toLowerCase());
    const authentication=(message.headers.get('Authentication-Results') || '').split(',')[0];
    const authenticatedDomain=/^mx\.cloudflare\.net\s*;/i.test(authentication)
      ? authentication.match(/;\s*dmarc=pass\s+header\.from=([a-z0-9.-]+)(?:\s|;|$)/i)?.[1]?.toLowerCase() : undefined;
    if(message.headers.get('X-AIOps-Summary')==='true' || !authenticatedDomain) {
      await message.forward(env.FORWARD_TO);return;
    }
    if(message.rawSize>256000) {await message.forward(env.FORWARD_TO);return;}
    const bytes=await new Response(message.raw).arrayBuffer();
    const email=await PostalMime.parse(bytes);
    const sender=email.from?.address?.toLowerCase();
    if(!sender || !allowed.includes(sender) || sender.split('@')[1]!==authenticatedDomain) {
      await message.forward(env.FORWARD_TO);return;
    }
    const subject=(email.subject || '').slice(0,500);
    if(subject.startsWith('[AIOps ') || /^\[OK\]/i.test(subject) || /^Verify email address on Healthchecks\.io$/i.test(subject) || /upgrade report validation/i.test(subject)) {await message.forward(env.FORWARD_TO);return;}
    const text=(email.text || email.html?.replace(/<[^>]*>/g,' ') || '').slice(0,20000);
    const digest=await crypto.subtle.digest('SHA-256',bytes);
    const id=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
    const envelope={id,receivedAt:new Date().toISOString(),from:sender,host:emailHost(subject),subject,text};
    await env[routeEmail(subject,text,env.MINI_SERVICES)].send(envelope);
    await message.forward(env.FORWARD_TO);
  }
};
