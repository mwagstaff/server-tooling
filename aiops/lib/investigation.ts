import type {Config, Incident} from './types.ts';

const checkHelp:Record<string,[string,string]> = {
  process:['Service process is stopped','Inspect the process-manager logs and exit reason before considering a restart.'],
  endpoint:['Local health endpoint failed','Inspect the health response and application logs for dependency failures.'],
  public:['Public endpoint failed','Compare local health with the public endpoint, tunnel and proxy logs.'],
  dailyJobRecent:['Nightly import is overdue','Check the last completed run and worker scheduling logs.'],
  dailyJobCompleted:['Nightly import has not completed','Check whether the worker is still running and inspect its latest progress logs.'],
  dailyJobSucceeded:['Nightly import has failed sources','Inspect failedSources and their timestamps. Review a retry only for failed sources after the worker is idle.'],
  ollamaUpdateStateReadable:['Ollama updater state is unavailable','Inspect ~/.local/share/ollama-updater/state.json and ~/Library/Logs/ollama-updater/ on the affected host.'],
  ollamaUpdateCheckFresh:['Ollama release check is overdue (72 hours)','Inspect the updater LaunchAgent and ~/Library/Logs/ollama-updater/ for release-check failures.'],
  ollamaUpdateHealthy:['Ollama updater recorded an error','Read healthError, blockedVersions and the updater logs. Preserve the maintenance gate and rollback state.'],
  ollamaUpdateTimely:['Ollama update has been pending for at least 14 days','Compare pendingSince with lastUpgradeAt, installed/latest versions and reviewRequired. Inspect ~/.local/share/ollama-updater/history.jsonl and ~/Library/Logs/ollama-updater/; a successful upgrade should reset the patch-update waiting period.'],
  ollamaUpdateNotStuck:['Ollama update transaction exceeded 45 minutes','Inspect phase, transactionStartedAt and updater logs. Do not restart a draining worker or remove its maintenance gate.']
};

export function explainChecks(checks:Record<string,boolean> = {}) {
  return Object.entries(checks).filter(([,ok])=>ok===false).map(([key])=>({key,
    title:checkHelp[key]?.[0] || `Health check failed: ${key}`,
    nextStep:checkHelp[key]?.[1] || `Inspect the ${key} check evidence and service logs before choosing a recovery action.`}));
}

// Structured observations remain authoritative even when a model ignores a failing check.
export function incidentGuide(i:Incident) {
  const worker=i.evidence?.workerHealth;
  const failures=explainChecks({process:i.evidence?.status?.active,endpoint:i.evidence?.health?.ok,
    public:i.evidence?.public?.ok,...i.evidence?.checks,...(i.alert.name.startsWith('Ollama')?worker?.ollamaUpdate?.checks:worker?.checks)});
  const summary=failures.length ? `Failed checks at ${worker?.checkedAt || i.updated}: ${failures.map(f=>f.title+' ('+f.key+')').join('; ')}.` : '';
  const context=worker?.checks?.dailyJobSucceeded===true && failures.length
    ? 'The nightly import succeeded, but these separate health requirements failed. HTTP 200 proves liveness only.'+
      (failures.some(f=>f.key.startsWith('ollamaUpdate'))?' A worker restart or successful-job retry will not repair an updater problem.':'') : '';
  return {failures,summary,context,nextSteps:i.evidence?.actionItems?.length ? i.evidence.actionItems as string[] : failures.map(f=>f.nextStep)};
}

// Rechecks replace current evidence; retain the original failing observation from the journal.
export function updaterFailureEvidence(i:Incident,events:{at:string;kind:string;data:any}[]) {
  if(i.service!=='kidsplorers-events-worker')return null;
  const snapshots=[...events.filter(e=>e.kind==='evidence'||e.kind==='health_recheck').map(e=>({
    at:e.at,worker:(e.kind==='health_recheck'?e.data.evidence:e.data)?.workerHealth})),
    {at:i.updated,worker:i.evidence?.workerHealth}];
  const snapshot=snapshots.find(s=>explainChecks({...s.worker?.checks,...s.worker?.ollamaUpdate?.checks}).some(f=>f.key.startsWith('ollamaUpdate')));
  if(!snapshot)return null;
  const worker=snapshot.worker;
  const update=worker.ollamaUpdate || {};
  const stamp=(value:any)=>typeof value==='number' && Number.isFinite(value) && value>0 ? new Date(value*1000).toISOString() : 'Not recorded';
  return {observedAt:worker.checkedAt || snapshot.at,
    failures:explainChecks({...worker.checks,...worker.ollamaUpdate?.checks}).filter(f=>f.key.startsWith('ollamaUpdate')),
    explanation:'This alert came from the Ollama updater health checks, not worker HTTP requests. Successful /status requests can return 200 while an updater check fails.',
    fields:{'Installed version':update.installedVersion || 'Not recorded','Latest version':update.latestVersion || 'Not recorded',
      'Pending since':stamp(update.pendingSince),'Last successful upgrade':stamp(update.lastUpgradeAt),
      'Last release check':stamp(update.lastCheckAt),'Updater phase':update.phase || 'Not recorded',
      'Recorded error':update.healthError || 'None recorded'},
    clockMismatch:typeof update.pendingSince==='number' && typeof update.lastUpgradeAt==='number' &&
      update.pendingSince<update.lastUpgradeAt && update.reviewRequired===false,
    snapshot:worker};
}

export function investigationLinks(config:Pick<Config,'publicUrl'>, host:string, service:string, startsAt?:string, endsAt?:string) {
  const grafana=new URL(config.publicUrl);grafana.port='13000';
  const start=Date.parse(startsAt || ''),end=Date.parse(endsAt || '');
  const params=new URLSearchParams({'var-host':host,'var-service':service,
    from:Number.isFinite(start)?String(start-15*60000):'now-1h',
    to:Number.isFinite(end)?String(Math.max(end,start || end)+5*60000):'now'});
  return {logs:`${grafana.origin}/d/monitoring-logs?${params}`,
    serviceMetrics:`${grafana.origin}/d/monitoring-service?${params}`,
    hostMetrics:`${grafana.origin}/d/monitoring-host?${params}`};
}
