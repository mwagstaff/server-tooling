# Adding service alerts that reach AIOps

Canonical agent guide for the active Mini/Sky estate. Checked against the
implementation on 20 October 2026. Read this before adding or changing service
monitoring, alert producers, email notifications or recovery procedures.

## Recommended approach

Prefer **application metrics → active Prometheus rules → Alertmanager → AIOps
and Pushover**. Use email for external tools and scheduled reports that cannot
export metrics. Pushover is a notification destination: AIOps does **not**
intercept Pushover messages. A new Pushover-only producer is a coverage gap.

| Service runs on | Monitoring and owning AIOps responder |
| --- | --- |
| Sky | Mini |
| Mini | Sky |

The alert's `host` means the affected host, not the responder. Both dashboards
display the estate; incident investigation and approvals belong to the owner.
Host-level alerts without a registered service receive manual triage.

Adding detection does not grant recovery permission. Existing policy allows
automatic recovery for the Top Scores pilot only; other services require
approval. Review the generated policy explicitly, especially for new names
beginning `top-scores-`, which the current generator treats as pilot services.

## Source of truth

Paths below are relative to the `server-tooling` repository.

| Change | Maintained source |
| --- | --- |
| Service, host, process, runtime port, metrics path, public URL | `monitoring/platform/inventory.json` |
| Application-specific rules | `monitoring/platform/application_rules.py` |
| Shared rules, scrape generation, routing and inhibition | `monitoring/platform/config.py` |
| Auxiliary Mini connectivity/sleep rules | `monitoring/platform/auxiliary-mini.json` |
| AIOps registry generation, health URLs, log paths, dependencies and action policy | `aiops/provision.py` |
| Generated registry deployed with AIOps | `aiops/config/services.json` |
| Restricted health/recovery implementation | `aiops/runner.py` |
| Email sender allowlist and Mini service routing list | `aiops/cloudflare/wrangler.jsonc` |
| Email parsing and filtering | `aiops/cloudflare/worker.mjs` |

Do not rely on editing generated files on a host. Make changes in their source
and deploy them. Do not use the retired Docker/Homebrew Prometheus stacks,
`install-alerting.zsh` or `configure-prometheus-rules.sh` for this estate.
A project's `observability/prometheus/rules.yml` is **not automatically imported**
by the active platform, and a normal application deployment does not register a
new service in this inventory.

## Adding a check to an existing service

1. Describe the failure being detected, its user impact, expected healthy value,
   tolerable delay and evidence needed to investigate it.
2. Prefer the existing `app_check_ok{check="<stable-check-name>"}` gauge:
   **1 = healthy, 0 = failing**. The active platform already alerts after five
   minutes, escalating to critical after thirty minutes. Confirm the service has
   a real `metrics_path` and is scraped successfully.
3. Use a custom rule in `application_rules.py` when thresholds, timing or
   severity differ. Use its existing `add(service, ...)` helper to preserve the
   registered service and affected host even after aggregation.
4. Include tests and a short service runbook, deploy the rule to the monitoring
   host, and complete the acceptance checks below.

For example, inside `application_rules()` after the `add` helper definition:

```python
add(
    'example-api', 'ExampleFeedStale',
    'time() - example_feed_last_success_timestamp_seconds{service="example-api"} > 1800',
    '5m', 'Example API feed has not updated successfully for thirty minutes'
)
```

This is a template, not an installed rule. Use the actual registered service ID,
real metric and a threshold based on its update schedule. The helper only adds
the rule when that service exists in the target inventory.

### Metric and rule conventions

- Scope application expressions to `service="<registered-id>"`. Preserve `host`
  and `service` through aggregation or explicitly restore them in rule labels.
  Do not confuse the exporter with a failing upstream: the Top Scores API,
  for example, exports its BSD upstream metrics.
- Give every alert a stable `alertname`, affected `host`, exact `service`,
  `severity` (`warning` or `critical`) and actionable `annotations.summary`.
  Add a service runbook link in `annotations.runbook_url` where available.
  The current AIOps intake uses the summary, so put the essential diagnosis
  context there rather than only in `description` or a linked page.
- Keep labels bounded and stable. Do not use request IDs, timestamps, raw URLs,
  exception text, user identifiers or secrets as labels. Put sanitized context
  in logs/annotations. Labels affect alert identity and deduplication.
- Set a persistence period appropriate to normal retries, startup and traffic.
  For error ratios, include a meaningful traffic floor. Test recovery as well
  as failure; avoid alerts that remain true forever after one historical error.
- Missing metrics are not a healthy value. An `up` alert detects failed scrapes,
  but not a metric that disappears from a successful scrape. Add a scoped
  absence/freshness check for required business metrics.
- For scheduled work, check last successful completion, failed results and
  maximum run duration. Persist the evidence across restarts. A live worker
  process alone does not prove that yesterday's job completed.
- Avoid duplicating existing runtime, public endpoint and dashboard health
  alerts. Review inhibition when adding warning/critical pairs or several
  symptoms of the same outage. Suppression must not hide unrelated services.

## Registering a new service

1. Add its actual deployed process to `platform/inventory.json`: unique service
   name, affected host, directory, entry, unit, wrapper, application port and a
   unique runtime port on that host in `19200–19399`. Set `metrics_path` to null
   when no native metrics endpoint exists. Include a meaningful `public_url`
   for externally reachable services.
2. Check `aiops/provision.py` generates the right local health URL, log paths,
   dependencies, owner and recovery policy. Add explicit handling for exceptions
   to its defaults. Change the generator rather than only its generated JSON.
3. Generate and review the registry with `python3 aiops/provision.py`.
   This step alone does not install the target's private runner configuration.
4. Install monitoring in the appropriate direction without `--skip-target`
   (see commands below). This may restart a newly instrumented application.
   Keep metrics private through the existing peer-restricted gateway.
5. Provision the private runner configuration and deploy AIOps to both hosts.
   The supported `python3 aiops/provision.py --apply` operation also rotates
   the shared peer token: coordinate deployment/restart of **both** responders
   immediately afterwards. Preserve existing private state and dashboard policy;
   never delete state or print credentials as part of onboarding.
6. For a new Mini email-producing service, also update the Worker's
   `MINI_SERVICES` list and deploy it. Updating the AIOps registry alone does
   not update Cloudflare routing.
7. Verify health on both dashboards and the target-side runner. Automatic
   actions require a separately reviewed, registered procedure and policy.
   A retry must be idempotent; a restart must be safe for active jobs.

See [AIOps operations](../aiops/README.md#deployment-and-configuration) for
provisioning and deployment. The current `redeploy` action restores a verified
code snapshot and restarts; it does not fetch new code or run migrations.
Refresh healthy snapshots after intentional application releases.

## Email and custom alert producers

Send failure/review email to **alerts@skynolimit.dev**. Before relying on it:

- Add the exact sender to `ALLOWED_SENDERS` in the Worker configuration. The
  receiving Cloudflare authentication result must show DMARC success aligned
  with the visible From domain. Do not disable authentication to make a test pass.
- Name exactly one registered service in the subject/body; include the affected
  host and a concise failure summary, time and sanitized evidence. Example:
  `[FAIL] sky / top-scores-scraper / scheduled scrape missed`.
- Avoid mentioning other service IDs in footers or templates. Multiple matching
  services cause manual triage. For host-only reports, put `mini` or `sky` in
  the subject; `monitoring-mini` and `monitoring-sky` are recognized.
- Success mail beginning `[OK]`, AIOps summaries and certain verification messages
  are forwarded to Gmail without creating incidents. Unapproved/unauthenticated
  mail is also forwarded only; Gmail receipt does **not** prove AIOps ingestion.
- Email has no structured source-resolution signal. Prefer metrics for a
  condition that needs reliable firing/resolved lifecycle tracking.

A custom structured producer can use the authenticated
`/webhooks/alertmanager` endpoint, but must implement the Alertmanager envelope,
stable labels/start time, retries and explicit resolved updates. Read
`aiops/lib/alerts.ts` and the server authentication before implementing it.
Direct webhook delivery alone does not provide the active Alertmanager source
state required for automatic recovery; use real Alertmanager routing for that.
Do not embed webhook tokens in source or expose the endpoint publicly.

Preserve independent Pushover delivery for ordinary alerts. Preserve the special
routes: `MonitoringWatchdog` goes to Healthchecks.io, and `AIOpsPipelineCanary`
goes only to AIOps. Do not use reserved watchdog/canary names for application
alerts because intake intentionally excludes them from incident creation.

## Deploy and verify

Run from the repository root. For **rule-only** updates, retain installed secrets
and skip target instrumentation:

```sh
# Rules monitoring Sky applications:
python3 monitoring/platform/install.py --monitor mini --target sky --skip-target --keep-secrets
# Rules monitoring Mini applications:
python3 monitoring/platform/install.py --monitor sky --target mini --skip-target --keep-secrets
```

Run only the affected direction, or both for shared rule changes. For new
services or metrics endpoints omit `--skip-target`. `--keep-secrets` assumes
required credentials already exist; provision a new metrics credential through
the documented vault workflow when needed.

Add rule scenarios to `platform/coverage.test.json` or `platform/rules.test.json`
and run:

```sh
python3 -m unittest discover -s monitoring/platform -p 'test_*.py' -v
```

Set `PROMTOOL` to an installed promtool executable so rule scenarios actually
run; skipped promtool tests are not evidence of passing rules. Test healthy,
brief failure, sustained failure, resolution, missing/stale data and preservation
of target labels as applicable.

For AIOps changes, run `npm run check`, `npm test` and
`python3 -m unittest discover -s test -p 'test_*.py'` from `aiops/`.
For Worker changes, run `npm ci`, `npm test` and `npx wrangler deploy` from
`aiops/cloudflare/`.

### Acceptance checklist for agents

- [ ] Expected targets are up and required metrics exist in the active Prometheus
      on the opposite host (loopback port `19090`, not legacy `9090`).
- [ ] Rules load without evaluation errors; emitted labels identify the right
      host/service. Inspect the evaluated result, not just source syntax.
- [ ] The active Alertmanager (loopback `19093`) routes ordinary alerts to
      **both `aiops` and `pushover`**, accounting for silences and inhibition.
- [ ] A bounded synthetic rule or disposable fixture exercises the real path:
      rule fires → owning responder records incident → summary notifications
      succeed → source resolves. A direct webhook test alone does not validate
      rule evaluation or routing. Use a dedicated unregistered test service to
      avoid recovery actions; separately validate the real service's labels.
- [ ] For email changes, a real authenticated test email reaches the correct
      responder and produces a summary, as well as the Gmail copy.
- [ ] Tests induce no production outage or unintended recovery. Remove temporary
      rules/fixtures and confirm no test alert remains firing.
- [ ] Both dashboards show fresh healthy service status; notification backlog
      and delivery canaries remain healthy.
- [ ] Record changed files, deployed hosts, test incident IDs, observed delivery
      and resolution, recovery permissions, and remaining limitations.

Canaries cover webhook and Worker→queue→consumer delivery. They do **not** prove
SMTP/DMARC delivery or the correctness of every application rule. Never describe
a service as covered solely because its process is up or its dashboard is green.

## Runbook content to keep with each service

Record its registered ID and host, schedule/expected behaviour, health and metrics
endpoints, failure thresholds, log locations, dependencies, safe recovery steps,
actions requiring approval, and post-recovery verification. State what the
checks cannot detect. Keep that runbook and this integration updated when moving,
renaming or retiring a service; remove obsolete rules, registry entries and email
routing entries together.

## Planned deployment and reboot windows

`deploy/node_project.zsh` requests a **180-second** maintenance window immediately
before stopping/restarting services on Mini or Sky, after dependency installation
and builds. It maps the actual service unit labels through the monitoring inventory,
including every process in a multi-service deployment. Assets-only and disable
operations do not create a temporary window. Set `DEPLOY_MAINTENANCE_SECONDS`
to override the duration (30–1800 seconds). A long restart can outlast its window;
choose a duration that covers its observed startup time.

Deployment hooks also pass `--planned-restart`, which writes one short-lived,
per-runtime marker on the target after maintenance succeeds. The Node runtime
consumes the marker on its next start and persists unexpected restart timestamps
under `~/.local/share/server-tooling-monitoring/runtime-state/`. Each deployment
excuses **one** start; crashes after that start count even within the maintenance
window. Expired markers do not excuse a start. A cancelled deployment can leave
its unused marker valid until that same short expiry; no long silence is added.

`RestartLoop` uses `monitoring_unplanned_restarts_15m >= 3`. Old runtime versions
and failed accounting fall back to process-start changes, preserving detection.
The first start after upgrading establishes a baseline; previous restart history
cannot be classified retrospectively. Runtime upgrades take effect on the next
service start. The dashboard's total restart count still includes deployments.
State loss establishes a fresh baseline, so preserve the runtime-state directory.
Manual restarts outside the deployment hook count as unplanned; ordinary
operator maintenance windows do not implicitly grant a planned-start credit.

The controller calls `monitoring/maintenance.py`, which uses SSH to the owning
responder and its existing private credential to POST `/api/maintenance`.
The authenticated endpoint creates expiring Alertmanager silences and persists
matching AIOps maintenance state. Pushover and AIOps webhook notifications are
silenced; matching email/queued incidents wait without model calls or recovery.
After expiry, healthy service incidents clear without a summary; persistent
failures resume normal investigation. Host-only emails without a registered
service still require manual triage after expiry because process health alone
cannot prove their underlying condition resolved.

Windows persist across responder restarts and expire even if the deployment
fails or disconnects. They are not global pause switches and do not require an
EXIT trap. Service windows leave unrelated services monitored. A deployment of
multiple public services also silences `SharedPublicOutage` for that host for
the same short period. Individual alerts for unrelated services remain enabled.
A failed maintenance request prints a warning and deployment continues with
monitoring enabled; no successful suppression is claimed. An already-running
recovery prevents creation of a maintenance window. A model request already in
flight cannot be undone, but recovery checks maintenance again before mutation.

For an operator-requested window, from the repository root:

```sh
python3 monitoring/maintenance.py --host sky --unit com.top-scores.api --seconds 180 --reason 'Planned API restart'
python3 monitoring/maintenance.py --host sky --host-wide --seconds 600 --reason 'Planned host reboot'
```

The endpoint body is `{ "host": "sky", "services": ["top-scores"],
"seconds": 180, "reason": "Planned API restart" }`. An empty services array
means host-wide maintenance. It accepts the owning responder's webhook token or
shared peer token, validates scope/duration and never exposes credentials in
command output. The response records the expiry and silence IDs. Windows are
recorded in the AIOps event journal under `maintenance`; Alertmanager also shows
the silences with creator `aiops-maintenance`.

The Ubuntu maintenance installer installs the same helper for scheduled/conditional
reboots when the SSH user's AIOps state exists. It requests a **600-second** host
window from the peer before rebooting, after checking package locks and reboot
need. The peer remains available while the target restarts. No reboot is performed
when installing this hook. If the peer is unavailable, reboot proceeds with a
recorded warning and monitoring remains enabled.

External Healthchecks.io watchdogs remain independent: these windows do not pause
Healthchecks or its direct Gmail notifications. Watchdog and pipeline canary
routes remain enabled. Scheduled package upgrades that restart services without
using the reboot/deployment hooks are not automatically covered by these windows.

## AIOps runbook and relay acceptance

AIOps records a reviewed versioned runbook per investigation; see
[runbooks](../aiops/runbooks/README.md). Registered application alerts accidentally
sent to the target's local Alertmanager are relayed to the owning responder's
Alertmanager over the authenticated private peer route. Prefer the canonical
metrics path for new producers. Relays preserve source expiry and resolution and
do not grant actions. Validate both owner intake and source checks when changing
producer labels or routing. Reconciliation includes suppressed alerts and requires
two full snapshots before interpreting disappearance as source resolution.
