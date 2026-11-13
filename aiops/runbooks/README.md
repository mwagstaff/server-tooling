# AIOps reviewed runbooks

Executable source: `../lib/runbooks.ts`. Increment the version when changing diagnostic or action policy. Alert text and incident evidence cannot change these instructions. The catalogue restricts actions; it never grants recovery permission beyond the service registry.

## Notification delivery failures (notification-delivery, v1)

1. Identify the failing integration and reason, and correlate Alertmanager logs with the incident window.
2. Check rejected intake records and reconciliation alerts on the same host before assuming an SMTP failure.
3. Compare attempts and failures for the same integration. Successful delivery API calls do not prove inbox receipt.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Source cleared and successful attempts in every affected integration without new failures.
- Escalation: Persistent failure or missing evidence requires review; do not restart applications.

## Stalled alert reconciliation (alert-reconciliation, v1)

1. Check last successful reconciliation, upstream reachability and rejected intake records.
2. Validate canonical host/service labels and owning responder; isolate malformed entries without hiding them.
3. Correlate notification failures within ten minutes as a possible shared intake issue, not a proven root cause.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Fresh completed reconciliation and source cleared.
- Escalation: Escalate persistence/storage/authentication failures; never bypass validation.

## Upstream import failure (upstream-import, v1)

1. Read the source HTTP/error evidence and reported last successful dataset update.
2. Keep the last validated dataset and expose its age; do not replace it with empty or unvalidated data.
3. For 403/authentication/browser challenges, do not restart a healthy application or bypass access controls.
4. Leave retries to the importer: bounded exponential backoff and its normal schedule; do not add parallel retries.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: A successful validated import and a matching resolved source alert; API health alone is insufficient.
- Escalation: Persistent upstream rejection or unacceptable dataset age requires operator review.

## Unexpected restart loop (unexpected-restarts, v1)

1. Compare unexpected restart accounting with total process starts and deployment events.
2. A deployment excuses one start only. Inspect timestamped exits, OOM evidence and process-manager state.
3. Historical startup log lines alone do not prove a loop; a further restart is not a remedy.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Unexpected restart rate cleared, process stable and service/public checks pass.
- Escalation: Escalate crash/OOM causes or missing accounting evidence.

## Upgrade and maintenance review (upgrade-review, v2)

1. Read only the report's Needs attention list; table labels such as "Failed system services: None" are not warnings. Each warning describes the report time.
2. Check the host now through the read-only runner: boot time, running and newest installed kernel, `/run/reboot-required`, failed system units and core unit activity.
3. Mark a warning resolved only from current evidence. Package, needrestart and log warnings need root, so they stay unverified with the exact command to run.
4. Classify active-session/inhibitor blocks as deferred; never force reboot or terminate user sessions. Phased or held updates are pending rollout, not failed upgrades.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Every reported warning verified resolved on the host now (status `healthy`).
- Escalation: List each pending or unverified warning with its specific next step; the daily 04:00 UK reboot check handles pending reboots.

v1 matched keywords anywhere in the report, so table labels produced findings, and it never inspected the host. On 8 November 2026 it reported REVIEW NEEDED with five generic findings, three of them false. In fact Sky had rebooted into the new kernel 27 seconds after the report and both real warnings were resolved.

## Logging pipeline failure (logging-pipeline, v1)

1. Check collector health, drop reason, canary freshness, backpressure and storage space.
2. Compare current and incident-time evidence; preserve buffered logs and do not clear state to hide failures.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Fresh canary and no new drops, with storage and collector checks passing.
- Escalation: Escalate data loss or unavailable historical evidence.

## Kidsplorers nightly event ingestion (events-worker-job, v5)

1. Read `workerHealth`: individual checks, running flag, run timestamps/counts and failed sources. HTTP 200 alone is liveness.
2. Correlate JSON `time` event timestamps; one failed source means a partial import failure, not a crashed worker.
3. Check `~/Library/Logs/ollama/serve.log` at the source failure time. On 29 October an MLX cache panic (`offset 5631 exceeds 5630 stored keys`) terminated a stream after HTTP 200; Ollama replaced its subprocess automatically. Invalid JSON alone does not prove that cause.
4. The worker retries incomplete/malformed model output up to three times (four attempts total) in its existing queue. Persistent failures remain unhealthy; retain previous source data.
5. Read `workerHealth.ollamaUpdate` and its individual checks. Inspect the updater journal, installed/latest versions, maintenance owner and active jobs. See [Ollama updater operations](../../ollama/README.md). The updater owns transactional rollback; AIOps does not install releases or clear gates.
6. The registered retry procedure (approval required) POSTs `/retry-failed` locally: it reruns only the last nightly run's failed sources and counts each that now succeeds in that run. Propose it once for transient failures while the worker and the Ollama updater are idle; a source that fails again needs review. Do not restart/redeploy to repair source results. An operator can POST `/run` locally for a full rerun only after checking the worker and downstream work are idle.

- Permitted runbook actions: none, retry (approval required; no automatic recovery).
- Recovery evidence: completed full run, or approved retry, leaving zero failed sources, fresh dashboard checks and source alert resolution.
- Escalation: persistent source/model failures with timestamped evidence; do not reset state or weaken checks.

## Service health investigation (service-health, v1)

1. Collect timestamped process, health, public endpoint, dependency, metrics and log evidence.
2. Separate upstream, deployment and infrastructure causes from application failures.
3. Use only independently registered recovery procedures; uncertain causes require review.

- Permitted runbook actions: none, restart, redeploy (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Three fresh service/public checks and source resolution; action success alone is insufficient.
- Escalation: Escalate uncertainty within the incident budget, then request review.

## Lessons become reviewed changes

For a new incident pattern: preserve incident-time evidence; separate observed symptoms from hypotheses; update the relevant versioned runbook; add a regression reproducing the trigger and resolution; review ownership and recovery restrictions; deploy responders sequentially; verify real source and delivery state. Do not automatically learn new commands or permissions from logs, email, or model output.

## BSD upstream failures (bsd-upstream, v1)

TopScoresBSDUpstreamErrors and TopScoresBSDUpstreamErrorsCritical inspect
BSD outbound counts by source/status, ratios, poll age and bounded bad URLs,
both at alert start and now. Inbound API 200s do not establish upstream health.
Missing evidence must not be interpreted as zero. This deterministic read-only
path cannot restart or redeploy services, and does not spend a model budget.
Recovery requires source resolution and recent successful BSD requests.

Warnings require >=10 transport/5xx failures and >=5% over 10m, recent failures
in 2m and persistence for 3m. Critical requires >=10 and >=50% over 5m, recent
failures in 1m and persistence for 2m. API and BSD poller are evaluated separately.
These rules do not classify 4xx/authentication/throttling as upstream 5xx failures;
the bad-URL table still records them. Existing scrape and freshness checks are
independent. Prometheus increase estimates counts and handles counter resets;
URL gauges retain six hours in memory and reset on application restart.

Updater check failures are assessed from structured evidence before model diagnosis. A successful nightly import and HTTP 200 do not override a failed updater check. The console and summary name each failing requirement, its observation time and investigation steps. Compare `pendingSince` with `lastUpgradeAt` when update timeliness fails; successful patch upgrades reset the patch waiting period, while major/minor review retains its age. No worker retry/restart is proposed for updater failures.

## Ollama updater maintenance (ollama-updater, v1)

`OllamaUpdateOverdue`, `OllamaUpdaterUnhealthy` and `OllamaUpdaterTelemetryMissing`
are component maintenance alerts, not worker outages. Read updater checks and
request outcomes separately from worker ingestion. The only automatic procedure
is `update_ollama`, limited to an authoritative overdue patch alert, fresh safe
state and enabled policy. Requests expire after ten minutes, defer busy work,
retry at thirty-minute intervals at most three times, and preserve the existing
transactional updater safeguards. Escalate failed/blocked/major/minor changes.
