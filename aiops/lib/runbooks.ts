import type {Incident} from './types.ts';
export type Runbook={id:string;version:number;title:string;steps:string[];allowedActions:string[];recovery:string;escalation:string};
const book=(id:string,title:string,steps:string[],recovery:string,escalation:string,allowedActions=['none']):Runbook=>({id,version:1,title,steps,allowedActions,recovery,escalation});
export const runbooks = {
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
  restarts:book('unexpected-restarts','Unexpected restart loop',[
    'Compare unexpected restart accounting with total process starts and deployment events.',
    'A deployment excuses one start only. Inspect timestamped exits, OOM evidence and process-manager state.',
    'Historical startup log lines alone do not prove a loop; a further restart is not a remedy.'
  ],'Unexpected restart rate cleared, process stable and service/public checks pass.','Escalate crash/OOM causes or missing accounting evidence.'),
  maintenance:book('upgrade-review','Upgrade and maintenance review',[
    'Distinguish historical upgrade warnings from current failed services.',
    'Classify active-session/inhibitor blocks as deferred; never force reboot or terminate user sessions.',
    'Treat phased updates as pending rollout, not a failed upgrade; verify package policy before classifying.',
    'Treat recovered tunnel shutdowns separately from ongoing tunnel failures; verify current connectivity.'
  ],'Current service checks pass; deferred work remains explicitly listed until completed.','Review unresolved failures or stale sessions in the scheduled maintenance window.'),
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
  if(n==='MonitoringNotificationFailures'||n==='AIOpsNotificationFailures')return runbooks.notifications;
  if(n==='AIOpsReconciliationStalled')return runbooks.reconciliation;
  if(n==='TopScoresEloImportFailed')return runbooks.upstream;
  if(i.service==='train-track-planner' && n.startsWith('PlannerTimetable'))return runbooks.planner;
  if(n==='RestartLoop')return runbooks.restarts;
  if(n==='WeeklyUpgradeReview')return runbooks.maintenance;
  if(n.startsWith('Log'))return runbooks.logging;
  return runbooks.service;
}
export function maintenanceFindings(text:string):string[] {
  const findings:string[]=[];
  if(/old binaries|Restart required/i.test(text))findings.push('Reported outdated services or sessions: verify current needrestart output; preserve active sessions.');
  if(/reboot|inhibitor/i.test(text))findings.push('Reboot/maintenance outcome needs current verification; active-session blocks are deferred work, not permission to force reboot.');
  if(/packages.*upgrades available|Remaining upgrades/i.test(text))findings.push('Pending package updates: check phased/held status before treating this as an upgrade failure.');
  if(/Tunnel.*shutdown timeout|cloudflared/i.test(text))findings.push('Tunnel warning is historical until current service/connectivity checks confirm a continuing failure.');
  if(/Failed system services/i.test(text))findings.push('Check the named failed units now; a historical failed state may already have recovered.');
  return findings.length?findings:['Review the original report and current service/package state; report text alone cannot verify recovery.'];
}
