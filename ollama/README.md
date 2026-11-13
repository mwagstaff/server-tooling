# Mini Ollama unattended updates

`updater.py` manages the official standalone Apple Silicon distribution used by
Kidsplorers (`qwen3.5:9b`). It does not update models or use Homebrew.

## Policy and schedule

- LaunchAgent `com.server-tooling.ollama-updater` ticks every five minutes, including at load.
- Discover official stable releases daily. Install only patches in the installed
  major/minor series, published at least 48 hours ago.
- Automatic installation window: Wednesday 12:00–14:00 Europe/London (DST aware).
- New major/minor series require operator review. Failed candidates are blocked
  until reviewed; no endless reinstall loop.
- `--check-now` refreshes discovery. `--apply-now` bypasses only the weekly window,
  retaining age, patch, signature and validation requirements.

## Transaction

1. Download the complete official darwin archive; validate GitHub's SHA-256,
   safe archive paths/links, size limits, codesign and team `3MU9H2V9Y9`, and arm64.
2. Persist an owner UUID and close worker admission through localhost `/maintenance`.
   Nightly pipelines, inbox processing, manual `/run`, audits and CLI run-once
   respect the durable gate. Existing work finishes. Wait up to 20 minutes for
   tracked jobs, existing CLI processes and Ollama TCP clients to drain.
   A busy worker defers installation and reopens admission without restarting.
3. Record 30-minute AIOps maintenance on the owning Sky responder. Failure to
   record it prevents switching. This suppression expires automatically.
4. Atomically switch `~/.local/share/ollama/current` and reload the existing Ollama
   LaunchAgent in its current domain, preserving its environment. Retain the
   original `bin` distribution and previous releases.
5. Require the expected API version and three real streamed structured-output
   generations with the production model, repeated prefix and production context
   size. Require stream completion and exact JSON. This catches basic inference
   and cache regressions but cannot prove every ingestion prompt will succeed.
6. Persist commit before reopening admission. Failed/interrupted switches restore
   the previous distribution and repeat inference checks. Failed rollback keeps
   admission closed and raises unhealthy state; never resume onto an unverified model.

Single-writer flock prevents overlapping updater/installer runs. Atomic journal
writes allow recovery at the next tick. Unknown/corrupt worker gates fail closed.
Direct unmanaged Ollama clients must respect this maintenance window; the worker
and supplied CLI are gated, but the updater cannot prevent an unrelated client
from opening a connection after the drain check.

## Install and operate (on Mini)

Copy this directory to `~/dev/server-tooling/ollama`, then:

```sh
/usr/bin/python3 ~/dev/server-tooling/ollama/install.py
/usr/bin/python3 ~/.local/share/ollama-updater/updater.py --apply-now
# Enable only after the first observed upgrade passes:
/usr/bin/python3 ~/dev/server-tooling/ollama/install.py --enable
```

Installer prepares the managed symlink and backs up the original Ollama plist;
preparation alone does not enable the scheduler. It requires the worker version
with maintenance admission, the existing AIOps private configuration, and a working
Ollama LaunchAgent. The scheduler runs in Mini's available gui/user launchd domain;
it requires that user session/domain to be available after reboot.

State: `~/.local/share/ollama-updater/state.json`; audit: `history.jsonl` in the same
directory. Logs: `~/Library/Logs/ollama-updater/`. Worker gate: `maintenance.json`
in its configured state directory. Original plist backup: `original-ollama.plist`.
Staged archives and rollback releases are retained; review storage during maintenance.

## AIOps runbook

The events-worker-job v5 runbook reads updater evidence through the private runner.
Dedicated warning alerts on Sky cover updater maintenance separately from worker
process/ingestion health: `OllamaUpdateOverdue`, `OllamaUpdaterUnhealthy`, and
`OllamaUpdaterTelemetryMissing`. They retain the worker association and identify
`component=ollama-updater`. These checks do not make the worker unhealthy:

- state readable, installed/latest versions valid;
- release check less than 72 hours old;
- no persisted upgrade error;
- available newer version pending less than 14 days (including review-required series);
  successful patch upgrades reset this waiting period, while a major/minor release
  awaiting review retains its original age. Older journals are corrected on the next tick;
- transaction idle or less than 45 minutes old.

Metrics: `aiops_ollama_update_info` (installed/latest labels),
`aiops_ollama_update_last_check_timestamp_seconds`, and
`aiops_ollama_update_last_success_timestamp_seconds`.

For failures, inspect the journal, worker `/maintenance`, service health and Ollama
logs first. Do not delete state, clear a gate or restart a busy model to silence an
alert. Let the updater retry interrupted rollback. If rollback cannot validate,
repair the retained previous distribution/service under the gate, validate real
inference, then resume using the recorded owner. AIOps may request an eligible overdue patch through the registered `update_ollama` procedure; it cannot select commands, releases, remove gates or bypass validation.
After diagnosis, an operator can clear `healthError` or a reviewed blocked version
in the journal only while the scheduler is stopped and its lock is free. Preserve
history. Re-enable and check the full source-alert lifecycle.

An upgrade's smoke success does not establish ingestion success. Verify the next
completed nightly job has zero failed sources, fresh source timestamps and cleared
alerts. Existing job health checks remain authoritative throughout.

## Validation

Run `python3 -m unittest discover -s ollama -p 'test_*.py'` from server-tooling,
the AIOps runner/metrics tests, and worker maintenance/model-stream tests. Failure
fixtures cover corrupt/unsafe archives, incomplete generations, drain deferral,
rollback, failed rollback and crash recovery without stopping production jobs.

## Deployment verification — 29 October 2026

- Mini worker deployed with maintenance admission; live pause rejected `/run`
  with 503 and rejected a different owner's resume with 409, then reopened cleanly.
- First observed upgrade: 0.40.0 → 0.40.12 at 10:44:09 UTC. Publisher archive SHA-256:
  `1d1b4c2cf40d2a239f9b08a77384830800a8542c744a55f47247f9baf85b55d2`.
  Three production-model structured streams completed correctly. Version 0.40.13
  remained pending because it was younger than 48 hours.
- Scheduler enabled in `gui/501`, five-minute interval, initial exit code 0.
  Runtime updater and private AIOps runner hashes matched source. AIOps deployed
  sequentially to Sky and Mini. Sky scraped installed/latest versions and healthy
  worker state; all five updater checks passed. Existing recovery permissions unchanged.
- 50 worker tests, 13 updater tests and 26 runner tests passed; TypeScript checking
  passed. AIOps Node suite: 90/91 passed; existing infrastructure coverage failure
  lists `MongoBackupStale` and `MongoRestoreTestStale` (outside this change).
- Disposable unregistered service `ollama-updater-verification` exercised the real
  Prometheus → Alertmanager → owning Sky AIOps path. Incident
  `52642354-efef-45f6-9960-f17d8d991d48` delivered email and Pushover summaries.
  Temporary rule removed after delivery; source resolved at 10:49:21 UTC and both
  resolution notifications delivered. No test alert remains active. Production jobs
  were not failed or restarted for this test.
- Last full ingestion before the upgrade completed 27/27 sources at 09:06:25 UTC.
  The next overnight ingestion on 0.40.12 remains to be observed through normal job
  health checks; smoke tests do not substitute for that verification.

## AIOps overdue-patch recovery

With automatic recovery enabled, an authoritative firing `OllamaUpdateOverdue`
alert may queue a fixed `update_ollama` request. The restricted Mini runner
requires a fresh, readable, idle, error-free updater with a genuinely overdue
update and no major/minor review pending. It records one idempotent request in
`state.json` under the updater lock; no worker restart is performed.

The five-minute updater scheduler consumes requests within ten minutes. It
refreshes release discovery and retains the 48-hour age, same-series patch,
blocked-version, archive, signature, drain, maintenance, inference and rollback
checks. Only the weekly installation window is bypassed. Each accepted request
is a bounded authorization; pausing AIOps prevents further requests, but does
not cancel one already accepted or interrupt a transaction in progress.

Busy work yields a deferred result. AIOps can issue another request after thirty
minutes, at most three requests per incident. Failures, interrupted requests,
expiry and unavailable eligibility evidence require review rather than replay.
AIOps checks pending results once per minute and limits verification to 24 hours.
It waits quietly while queued/running/deferred, then reports verified recovery
or required review. Alertmanager's independent maintenance-warning delivery is
preserved. Updater recovery requires fresh updater checks plus source resolution;
worker impact is reported separately. Ordinary scheduled updates remain enabled.

### Deployment verification — 12 November 2026

- Both AIOps responders, Mini's restricted runner and transactional updater, and
  Sky's Mini-facing monitoring rules deployed. Automatic policy enabled; only
  `update_ollama` added to the worker's automatic procedure list.
- Live worker health = 1, updater health = 1, overdue = 0; all three new rules
  evaluate without errors. Worker process/ingestion checks exclude updater checks.
- 123 Node tests passed with the existing Mongo investigation-coverage failure;
  29 runner and 16 updater tests passed. 37 monitoring tests passed on Sky using
  its installed promtool, including overdue/resolution and missing telemetry.
- Disposable bounded `AIOpsUpdaterAcceptance` rule for unregistered service
  `aiops-updater-verification` exercised Prometheus → Alertmanager → Sky AIOps →
  email/Pushover, then source resolution. Incident
  `43640148-2856-4316-b508-f5d9e118ae54`, zero actions, both initial and resolved
  notifications accepted. Temporary rule removed; no acceptance alert active.
- No production update was forced: 0.40.15 remains installed; 0.40.16 is not
  overdue. Installation/deferral/rollback outcomes were exercised with fixtures;
  a future genuine overdue update remains the production proof of that action.
