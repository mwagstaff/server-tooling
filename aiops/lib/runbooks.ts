import type {Incident} from './types.ts';
export type Runbook={id:string;version:number;title:string;steps:string[];allowedActions:string[];recovery:string;escalation:string};
const book=(id:string,title:string,steps:string[],recovery:string,escalation:string,allowedActions=['none'],version=1):Runbook=>({id,version,title,steps,allowedActions,recovery,escalation});
export const runbooks = {
  publicOutage:book('shared-public-outage','Shared public endpoint outage',[
    'Compare incident-time public failures, HTTP status and duration with current probes.',
    'Verify every registered and observed public target, successful collection and fresh samples.',
    'Recheck recent incidents once per minute; close only after public checks pass and the source alert clears.',
    'Persistent failures require proxy/tunnel, network and local-origin evidence. Shared infrastructure restarts require approval.'
  ],'Fresh complete public probes pass and source alert clears.','Missing telemetry or persistent failures require review.'),
  notifications:book('notification-delivery','Notification delivery failures',[
    'Identify the failing integration and reason, and correlate Alertmanager logs with the incident window.',
    'Check rejected intake records and reconciliation alerts on the same host before assuming an SMTP failure.',
    'Compare attempts and failures for the same integration. Successful delivery API calls do not prove inbox receipt.'
  ],'Source cleared and successful attempts in every affected integration without new failures.','Persistent failure or missing evidence requires review; do not restart applications.'),
  reconciliation:book('alert-reconciliation','Stalled alert reconciliation',[
    'Check last successful reconciliation, upstream reachability and rejected intake records.',
    'Validate canonical host/service labels and owning responder; isolate malformed entries without hiding them.',
    'Correlate notification failures within ten minutes as a possible shared intake issue, not a proven root cause.'
  ],'Fresh completed reconciliation and source cleared.','Escalate persistence/storage/authentication failures; never bypass validation.'),
  bsd:book('bsd-upstream','BSD upstream request failures',[
    'Inspect BSD request counts by source/status, failure ratios, poll freshness and bad URL evidence for both the incident time and now.',
    'Inbound API HTTP 200s and healthy processes do not establish BSD health. Missing BSD samples mean unavailable evidence, not zero failures.',
    'URL evidence is bounded to a six-hour rolling window and resets on process restart. Do not infer missing query parameters or provider root causes.',
    'Do not restart or redeploy a healthy application for upstream failures. Leave retries to the BSD client.'
  ],'Source alert resolved with fresh successful BSD requests; application health alone is insufficient.','Escalate sustained failures with timestamps, sources, status codes and retained URLs. No automatic recovery permitted.'),
  upstream:book('upstream-import','Upstream import failure',[
    'Read the source HTTP/error evidence and reported last successful dataset update.',
    'Keep the last validated dataset and expose its age; do not replace it with empty or unvalidated data.',
    'For 403/authentication/browser challenges, do not restart a healthy application or bypass access controls.',
    'Leave retries to the importer: bounded exponential backoff and its normal schedule; do not add parallel retries.'
  ],'A successful validated import and a matching resolved source alert; API health alone is insufficient.','Persistent upstream rejection or unacceptable dataset age requires operator review.'),
  planner:book('planner-ingestion','Planner timetable ingestion',[
    'Read plannerIngestion: lastCheckAt, lastFinishedAt, phase, lastResult, lastErrorCode and lastErrorMessage; compare their event times with the incident.',
    'Compare active baseline/current sequence and last activation. HTTP health proves serving, not successful ingestion.',
    'A full feed may be revised on the same date. Only a newer publication with the next sequence can replace a same-day baseline; retain validation and rollback.',
    'Never infer the cause from old startup errors or collection timestamps. Missing state or a generic error code is an evidence gap.'
  ],'Successful ingestion result and source alert resolved, with a validated active dataset.','Inspect rejected delivery metadata; do not restart a healthy service or delete locks.'),
  updater:book('ollama-updater','Ollama updater maintenance',[
    'Report worker ingestion/process health separately from updater maintenance. HTTP 200 does not verify an update.',
    'Only an overdue same-series patch may be requested automatically, after fresh checks and a firing source alert. The registered updater owns release age, draining, signatures, validation and rollback.',
    'Busy deferrals can be retried after 30 minutes, at most three requests per incident. Failed, interrupted, blocked or major/minor upgrades require review. Never clear a maintenance gate or replay a blocked version.'
  ],'Updater checks pass and the dedicated source alert resolves; report worker impact independently.','Inspect updater evidence and request outcome. Review failed upgrades or major/minor releases.',['none','update_ollama']),
  events:book('events-worker-job','Kidsplorers nightly event ingestion',[
    'Read workerHealth checks, running, lastRun and failedSources. HTTP 200 proves liveness only; dailyJobSucceeded requires zero failed sources and at least one success.',
    'Correlate source failure times and explicit JSON time fields with the run. A single failed source is a partial import failure, not a process outage.',
    'Inspect workerHealth.ollamaUpdate for update checks, installed/latest versions, lastOutcome, healthError, blockedVersions and phase. The local updater alone owns its bounded rollback. Never restart a draining worker, remove its maintenance gate, or replay a blocked version. Missing state, checks older than 72h, updates pending 14 days, or a transaction over 45 minutes require review.',
    'Every false workerHealth.checks value is a failed requirement, even when the nightly import succeeds. Name the failing check and its threshold before assessing health. For ollamaUpdateTimely, compare pendingSince with lastUpgradeAt; an older patch waiting timestamp after a successful upgrade indicates updater accounting needs repair. Updater failures require updater investigation, never a successful-job retry.',
    'Ollama can return HTTP 200 and then lose its MLX subprocess. Correlate ~/Library/Logs/ollama/serve.log with failedSources times; the 29 October incident recorded cache: offset 5631 exceeds 5630 stored keys followed by automatic subprocess replacement. Do not infer a cache crash from invalid JSON alone.',
    'Malformed or incomplete model output gets up to three serialized retries (four attempts total) inside the worker. Persistent failures remain unhealthy; never suppress the failed-source check or mark a run successful manually.',
    'The registered retry procedure (POST /retry-failed on loopback, approval required) reruns only the last nightly run\'s failed sources and counts each that now succeeds in that run. Propose it once for transient failures (timeouts, fetch failures, malformed model output) when running is false and the Ollama updater is idle; the rerun takes minutes, so verify after it finishes. A source that fails again after a retry needs review, not more retries. Never restart or redeploy a healthy process to repair a source result.'
  ],'Completed full run, or approved retry, leaving zero failed sources, fresh healthy dashboard checks and source alert resolution.','Escalate persistent source/model failures with timestamped evidence. Retry requires approval; no automatic recovery is granted.',['none','retry'],5),
  loading:book('darwin-feed','Train loading readiness and Darwin feed',[
    'Read loadingHealth even on HTTP 503: compare ready, Mongo health, feed state, transport age, MESSAGE age and lastError with checkedAt and the incident window.',
    'Liveness and process uptime distinguish a running service with an unavailable dependency from a crash. A subscribed socket or fresh heartbeats alone do not prove fresh Darwin data.',
    'ECONNREFUSED identifies a refused broker connection; it does not establish the provider internal cause. Stale messages with a live transport are a feed-delivery problem until further evidence is available.',
    'Keep the existing bounded reconnect/backoff. Do not restart a healthy process to repair an upstream feed, clear Mongo, or declare recovery from connection state alone.'
  ],'Fresh Darwin MESSAGEs, healthy Mongo, local/public readiness and resolved source alert.','Escalate persistent feed staleness or broker refusal with timestamps; investigate Mongo separately. Recovery actions require separate approval.'),
  restarts:book('unexpected-restarts','Unexpected restart loop',[
    'Compare unexpected restart accounting with total process starts and deployment events.',
    'A deployment excuses one start only. Inspect timestamped exits, OOM evidence and process-manager state.',
    'Historical startup log lines alone do not prove a loop; a further restart is not a remedy.'
  ],'Unexpected restart rate cleared, process stable and service/public checks pass.','Escalate crash/OOM causes or missing accounting evidence.'),
  maintenance:book('upgrade-review','Upgrade and maintenance review',[
    'Read only the report\'s Needs attention list; table labels such as "Failed system services: None" are not warnings. Each warning describes the report time.',
    'Check the host now through the read-only runner: boot time, running and newest installed kernel, /run/reboot-required, failed system units and core unit activity.',
    'Mark a warning resolved only from current evidence. Package, needrestart and log warnings need root, so they stay unverified with the exact command to run.',
    'Classify active-session/inhibitor blocks as deferred; never force reboot or terminate user sessions. Phased or held updates are pending rollout, not failed upgrades.'
  ],'Every reported warning verified resolved on the host now.','List each pending or unverified warning with its specific next step; the daily 04:00 UK reboot check handles pending reboots.',['none'],2),
  logging:book('logging-pipeline','Logging pipeline failure',[
    'Check collector health, drop reason, canary freshness, backpressure and storage space.',
    'Compare current and incident-time evidence; preserve buffered logs and do not clear state to hide failures.'
  ],'Fresh canary and no new drops, with storage and collector checks passing.','Escalate data loss or unavailable historical evidence.'),
  service:book('service-health','Service health investigation',[
    'Collect timestamped process, health, public endpoint, dependency, metrics and log evidence.',
    'Separate upstream, deployment and infrastructure causes from application failures.',
    'Use only independently registered recovery procedures; uncertain causes require review.'
  ],'Three fresh service/public checks and source resolution; action success alone is insufficient.','Escalate uncertainty within the incident budget, then request review.',['none','restart','redeploy'])
};
export function selectRunbook(i:Incident):Runbook {
  const n=i.alert.name;
  if(i.service==='kidsplorers-events-worker' && ['OllamaUpdateOverdue','OllamaUpdaterUnhealthy','OllamaUpdaterTelemetryMissing'].includes(n))return runbooks.updater;
  if(n==='SharedPublicOutage')return runbooks.publicOutage;
  if(n==='MonitoringNotificationFailures'||n==='AIOpsNotificationFailures')return runbooks.notifications;
  if(n==='AIOpsReconciliationStalled')return runbooks.reconciliation;
  if(n.startsWith('TopScoresBSDUpstream'))return runbooks.bsd;
  if(n==='TopScoresEloImportFailed')return runbooks.upstream;
  if(i.service==='train-track-planner' && n.startsWith('PlannerTimetable'))return runbooks.planner;
  if(i.service==='train-loading-service' && ['PublicEndpointUnavailable','ServiceHealthFailing','AppCheckFailing','AppCheckFailingLong'].includes(n))return runbooks.loading;
  if(i.service==='kidsplorers-events-worker' && n==='ServiceHealthFailing')return runbooks.events;
  if(n==='RestartLoop')return runbooks.restarts;
  if(n==='WeeklyUpgradeReview')return runbooks.maintenance;
  if(n.startsWith('Log'))return runbooks.logging;
  return runbooks.service;
}
// The report's "Needs attention" list (HTML relayed as text) or "ATTENTION" list (plain text).
export function reportedWarnings(text:string):string[] {
  const lines=text.split(/\r?\n/).map(line=>line.trim());
  const start=lines.findIndex(line=>/^(Needs attention|ATTENTION)$/i.test(line));
  const warnings:string[]=[];
  for(const line of start<0?[]:lines.slice(start+1)) {
    if(!line)continue;
    const item=/^[-*•]\s+(.+)$/.exec(line);
    if(!item)break;
    warnings.push(item[1].slice(0,300));
  }
  return warnings.slice(0,30);
}
type MaintenanceCheck={label:string;state:'resolved'|'pending'|'unverified';detail:string;action?:string};
// Compare each reported warning with current host evidence; unverifiable warnings get the exact command to run.
export function assessMaintenance(text:string,hostName:string,reportedAt:string,host:any) {
  const warnings=reportedWarnings(text), ok=Boolean(host && !host.error);
  const at=(iso:string)=>iso.slice(0,19).replace('T',' ')+' UTC';
  const run=(command:string)=>`Run \`${command}\` on ${hostName}`;
  const rebooted=ok && Date.parse(host.bootedAt)>Date.parse(reportedAt);
  const rebootCheck=ok && host.nextRebootCheck ? `the automatic reboot check at ${host.nextRebootCheck}` : 'the daily 04:00 UK automatic reboot check';
  const unknown=(label:string,command:string):MaintenanceCheck=>({label,state:'unverified',detail:ok?'needs root; not checked by AIOps':'host state unavailable',action:run(command)});
  const unit=(label:string,name:string):MaintenanceCheck=>!ok || !host.units?.[name] ? unknown(label,`systemctl status ${name}`) :
    host.units[name]==='active' ? {label,state:'resolved',detail:`${name} is active now`} :
    {label,state:'pending',detail:`${name} is ${host.units[name]} now`,action:run(`journalctl -u ${name} -b`)};
  const check=(warning:string):MaintenanceCheck=>{
    if(/reboot required|Running kernel/i.test(warning)) {
      if(!ok)return unknown('Reboot/kernel','cat /run/reboot-required.pkgs; uname -r');
      if(!host.rebootRequired && host.runningKernel===host.newestKernel)
        return {label:'Reboot/kernel',state:'resolved',detail:`${hostName} booted ${at(host.bootedAt)}${rebooted?', after this report':''}; running ${host.runningKernel}, the newest installed kernel; no reboot pending`};
      return {label:'Reboot/kernel',state:'pending',detail:`reboot pending${host.rebootPackages?.length?' for '+host.rebootPackages.join(', '):''}; running ${host.runningKernel}, newest installed ${host.newestKernel}`,
        action:`Reboot ${hostName} to load ${host.newestKernel}: ${rebootCheck} does this unless sessions or inhibitors defer it (check \`loginctl list-sessions\`)`};
    }
    if(/Failed system services/i.test(warning)) {
      if(!ok || !Array.isArray(host.failedUnits))return unknown('Failed units','systemctl --failed');
      if(!host.failedUnits.length)return {label:'Failed units',state:'resolved',detail:'no failed system units now'};
      const first=host.failedUnits[0];
      return {label:'Failed units',state:'pending',detail:`failed now: ${host.failedUnits.join(', ')}`,action:run(`systemctl status ${first}`)+` and \`journalctl -u ${first} -b\``};
    }
    if(/old binaries|needrestart/i.test(warning))return rebooted ?
      {label:'Old binaries',state:'resolved',detail:`${hostName} rebooted at ${at(host.bootedAt)}, after this report, restarting every process`} :
      {...unknown('Old binaries','sudo needrestart -b -r l'),action:run('sudo needrestart -b -r l')+`; ${rebootCheck} reboots if anything is still outdated`};
    if(/Cloudflare Tunnel/i.test(warning))return unit('Tunnel','cloudflared');
    const inactive=/^(\S+) is not active$/.exec(warning);
    if(inactive)return unit(inactive[1],inactive[1]);
    if(/Ubuntu security update|Pro\/ESM/i.test(warning))return unknown('Ubuntu Pro/ESM','pro security-status');
    if(/upgrades available|security updates available|Security update assessment/i.test(warning))
      return {...unknown('Package updates','apt list --upgradable'),action:run('apt list --upgradable')+'; phased or held packages need no action'};
    if(/Held packages/i.test(warning))return unknown('Held packages','apt-mark showhold');
    if(/Package database/i.test(warning))return unknown('Package database','sudo dpkg --audit');
    return {label:warning.replace(/:.*/,'').slice(0,60),state:'unverified',detail:'historical report finding; not checked by AIOps',
      action:`Read "${warning.slice(0,120)}" in the report's upgrade-details.txt attachment`};
  };
  const checks=[...new Map(warnings.map(check).map(c=>[c.label,c])).values()];
  const findings=checks.map(c=>`${c.label} — ${c.state}: ${c.detail}.`);
  if(!warnings.length)findings.push('Could not read the report\'s Needs attention list; nothing was verified.');
  if(!ok)findings.push(`Host evidence unavailable: ${host?.error || 'the runner did not report maintenance state'}.`);
  const resolved=warnings.length>0 && checks.every(c=>c.state==='resolved');
  const actionItems=resolved ? [`None — all ${warnings.length} reported warnings are resolved on ${hostName} now.`] :
    warnings.length ? checks.filter(c=>c.action).map(c=>c.action+'.') : ['Open the original weekly upgrade report and review its Needs attention list.'];
  return {warnings,checks,findings,actionItems,healthy:resolved?true:checks.some(c=>c.state==='pending')?false:null};
}
