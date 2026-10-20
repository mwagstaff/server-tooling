import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker,{routeEmail,emailHost} from './worker.mjs';

test('host maintenance and external watchdog alerts route to the opposite host',()=>{
  assert.equal(emailHost('[FAILED] sky weekly upgrade report'),'sky');
  assert.equal(routeEmail('[DOWN] monitoring-mini','','train-track-planner'),'SKY_QUEUE');
  assert.equal(emailHost('mini and sky'),undefined);
});
test('scheduled queue canaries exercise both queues without sending user mail',async()=>{
  const messages=[];
  await worker.scheduled({}, {MINI_QUEUE:{send:async e=>messages.push(e)},SKY_QUEUE:{send:async e=>messages.push(e)}});
  assert.equal(messages.length,2);
  assert.equal(messages[0].type,'aiops-queue-canary');
});

test('routes incidents to the opposite host',()=>{
  assert.equal(routeEmail('top-scores down','','train-track-planner'),'MINI_QUEUE');
  assert.equal(routeEmail('train-track-planner down','','train-track-planner'),'SKY_QUEUE');
});
test('unapproved sender is forwarded but cannot enqueue recovery',async()=>{
  let forwarded=0,queued=0;
  await worker.email({to:'alerts@example.com',from:'unknown@example.net',headers:new Headers(),
    forward:async()=>forwarded++},{ALERT_ADDRESS:'alerts@example.com',FORWARD_TO:'owner@example.com',ALLOWED_SENDERS:'trusted@example.net',
    MINI_QUEUE:{send:async()=>queued++}});
  assert.equal(forwarded,1);assert.equal(queued,0);
});
test('responder summaries cannot create alert loops',async()=>{
  let queued=0;
  await worker.email({to:'alerts@example.com',from:'trusted@example.net',headers:new Headers({'X-AIOps-Summary':'true'}),
    forward:async()=>{}},{ALERT_ADDRESS:'alerts@example.com',FORWARD_TO:'owner@example.com',ALLOWED_SENDERS:'trusted@example.net',
    MINI_QUEUE:{send:async()=>queued++}});
  assert.equal(queued,0);
});
test('trusted email queues an envelope and preserves the human copy',async()=>{
  let saved,forwarded=0;
  const raw='From: trusted@example.net\r\nTo: alerts@example.com\r\nSubject: top-scores unavailable\r\nContent-Type: text/plain\r\n\r\nService stopped.';
  await worker.email({to:'alerts@example.com',from:'unique-return@bounce.example.net',
    headers:new Headers({'Authentication-Results':'mx.cloudflare.net; dkim=pass header.d=example.net; dmarc=pass header.from=example.net policy.dmarc=none'}),
    rawSize:raw.length,
    raw:new Blob([raw]).stream(),forward:async()=>forwarded++},{
    ALERT_ADDRESS:'alerts@example.com',FORWARD_TO:'owner@example.com',ALLOWED_SENDERS:'trusted@example.net',MINI_SERVICES:'train-track-planner',
    MINI_QUEUE:{send:async e=>saved=e}});
  assert.equal(saved.subject,'top-scores unavailable');assert.equal(saved.id.length,64);assert.equal(forwarded,1);
  assert.equal(saved.from,'trusted@example.net');
});
test('forged or failed authentication cannot authorise an allowed sender',async()=>{
  for(const authentication of [
    'evil.example; dmarc=pass header.from=example.net',
    'mx.cloudflare.net; dmarc=fail header.from=example.net, mx.cloudflare.net; dmarc=pass header.from=example.net',
    'mx.cloudflare.net; dmarc=pass header.from=attacker.example'
  ]) {
    let queued=0,forwarded=0;
    const raw='From: trusted@example.net\r\nSubject: top-scores down\r\n\r\nStopped.';
    await worker.email({to:'alerts@example.com',from:'trusted@example.net',rawSize:raw.length,
      raw:new Blob([raw]).stream(),headers:new Headers({'Authentication-Results':authentication}),
      forward:async()=>forwarded++},{ALERT_ADDRESS:'alerts@example.com',FORWARD_TO:'owner@example.com',
      ALLOWED_SENDERS:'trusted@example.net',MINI_QUEUE:{send:async()=>queued++}});
    assert.equal(queued,0);assert.equal(forwarded,1);
  }
});
