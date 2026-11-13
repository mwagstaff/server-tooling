import test from 'node:test';
import assert from 'node:assert/strict';
import {incidentGuide,explainChecks,investigationLinks} from '../lib/investigation.ts';
import {enqueueSummary} from '../lib/notifications.ts';
import {Store} from '../lib/store.ts';
import type {Config,Incident} from '../lib/types.ts';

const incident={id:'fixture',key:'fixture',host:'mini',service:'kidsplorers-events-worker',
  status:'needs_review',created:'2026-11-12T10:41:00Z',updated:'2026-11-12T10:42:00Z',spent:0,attempts:0,
  alert:{source:'alertmanager',name:'ServiceHealthFailing',startsAt:'2026-11-12T10:41:00Z',summary:'Worker unhealthy'},
  diagnosis:'Service reports healthy. All checks pass.',verification:{healthy:false,alertFiring:true},
  evidence:{metrics:{restarts15m:{samples:[]}},workerHealth:{checkedAt:'2026-11-12T10:41:06Z',
    checks:{dailyJobSucceeded:true,ollamaUpdateTimely:false},lastRun:{ok:28,failed:0}}}} as Incident;

test('measured updater failure overrides misleading model prose in email',()=>{
  const store=new Store(':memory:');
  try {
    store.put(incident);
    enqueueSummary({publicUrl:'http://sky:19444',budgetUsd:1,notification:{}} as Config,store,incident);
    const text=store.events(incident.id).find(e=>e.kind==='summary')!.data.text;
    assert.match(text,/ollamaUpdateTimely/);
    assert.match(text,/nightly import succeeded/);
    assert.match(text,/pendingSince with lastUpgradeAt/);
    assert.doesNotMatch(text,/Service reports healthy|Five-minute window|Assessment requires/);
    assert.match(text,/ACTION REQUIRED/);
  } finally {store.db.close();}
});
test('unknown failed checks remain visible and missing evidence is not success',()=>{
  assert.equal(explainChecks({newCheck:false,process:true})[0].key,'newCheck');
  assert.equal(incidentGuide({...incident,evidence:{}}).summary,'');
});
test('investigation links carry service, host and incident time window',()=>{
  const links=investigationLinks({publicUrl:'http://sky:19444'},'mini','worker & service','2026-11-12T10:41:00Z','2026-11-12T10:42:00Z');
  const url=new URL(links.logs);
  assert.equal(url.port,'13000');assert.equal(url.pathname,'/d/monitoring-logs');
  assert.equal(url.searchParams.get('var-service'),'worker & service');
  assert.equal(url.searchParams.get('var-host'),'mini');
  assert.equal(url.searchParams.get('from'),String(Date.parse('2026-11-12T10:26:00Z')));
  assert.equal(new URL(investigationLinks({publicUrl:'http://sky:19444'},'mini','worker').logs).searchParams.get('to'),'now');
});

test('original updater failure survives a healthy recheck and explains the clock mismatch',async()=>{
  const {updaterFailureEvidence}=await import('../lib/investigation.ts');
  const worker={checkedAt:'2026-11-12T10:41:06Z',checks:{dailyJobSucceeded:true,ollamaUpdateTimely:false},
    ollamaUpdate:{installedVersion:'0.40.15',latestVersion:'0.40.16',pendingSince:1793270247,lastUpgradeAt:1794398477,reviewRequired:false}};
  const recovered={...incident,status:'healthy',evidence:{workerHealth:{checks:{ollamaUpdateTimely:true}}}};
  const evidence=updaterFailureEvidence(recovered,[{at:incident.created,kind:'evidence',data:{workerHealth:worker}}])!;
  assert.equal(evidence.snapshot,worker);assert.equal(evidence.clockMismatch,true);
  assert.equal(evidence.failures[0].key,'ollamaUpdateTimely');
  assert.match(evidence.fields['Pending since'],/^2026-10-29T/);
  assert.match(evidence.explanation,/not worker HTTP requests/);
  assert.equal(updaterFailureEvidence(recovered,[]),null);
  assert.equal(updaterFailureEvidence({...recovered,service:'other'},[{at:incident.created,kind:'evidence',data:{workerHealth:worker}}]),null);
});
test('updater email links to retained failure evidence and labels worker logs separately',()=>{
  const store=new Store(':memory:');
  try {
    store.put(incident);
    enqueueSummary({publicUrl:'http://sky:19444',budgetUsd:1,notification:{}} as Config,store,incident);
    const text=store.events(incident.id).find(e=>e.kind==='summary')!.data.text;
    assert.match(text,/- Failure evidence: http:\/\/sky:19444\/\?incident=fixture#failure-evidence/);
    assert.match(text,/- Worker request logs:/);assert.match(text,/- Log scope:/);
  } finally {store.db.close();}
});
