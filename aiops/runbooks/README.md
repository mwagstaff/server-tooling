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

## Upgrade and maintenance review (upgrade-review, v1)

1. Distinguish historical upgrade warnings from current failed services.
2. Classify active-session/inhibitor blocks as deferred; never force reboot or terminate user sessions.
3. Treat phased updates as pending rollout, not a failed upgrade; verify package policy before classifying.
4. Treat recovered tunnel shutdowns separately from ongoing tunnel failures; verify current connectivity.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Current service checks pass; deferred work remains explicitly listed until completed.
- Escalation: Review unresolved failures or stale sessions in the scheduled maintenance window.

## Logging pipeline failure (logging-pipeline, v1)

1. Check collector health, drop reason, canary freshness, backpressure and storage space.
2. Compare current and incident-time evidence; preserve buffered logs and do not clear state to hide failures.

- Permitted runbook actions: none (still subject to registry, ownership, source-state, budget and approval checks).
- Recovery evidence: Fresh canary and no new drops, with storage and collector checks passing.
- Escalation: Escalate data loss or unavailable historical evidence.

## Kidsplorers nightly event ingestion (events-worker-job, v3)

1. Read `workerHealth`: individual checks, running flag, run timestamps/counts and failed sources. HTTP 200 alone is liveness.
2. Correlate JSON `time` event timestamps; one failed source means a partial import failure, not a crashed worker.
3. Check `~/Library/Logs/ollama/serve.log` at the source failure time. On 29 October an MLX cache panic (`offset 5631 exceeds 5630 stored keys`) terminated a stream after HTTP 200; Ollama replaced its subprocess automatically. Invalid JSON alone does not prove that cause.
4. The worker retries incomplete/malformed model output up to three times (four attempts total) in its existing queue. Persistent failures remain unhealthy; retain previous source data.
5. Read `workerHealth.ollamaUpdate` and its individual checks. Inspect the updater journal, installed/latest versions, maintenance owner and active jobs. See [Ollama updater operations](../../ollama/README.md). The updater owns transactional rollback; AIOps does not install releases or clear gates.
6. AIOps has no registered retry procedure. Do not restart/redeploy to repair source results. An operator can POST `/run` locally only after checking the worker and downstream work are idle.

- Permitted runbook actions: none. Existing recovery permissions are unchanged.
- Recovery evidence: completed full run with zero failed sources, fresh dashboard checks and source alert resolution.
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
