# Private AIOps responder

For new service checks and alert producers, follow the
[alerting and AIOps integration guide](../monitoring/ALERTING.md), including
registration, delivery verification and recovery-policy review.

A small Node service for investigating alerts, running registered recovery procedures,
and recording the evidence, actions, final checks and notifications. Mini and Sky run
independently using the existing Node deployment script.

## Access and current rollout

| Responder | Private dashboard | Default inference |
| --- | --- | --- |
| Mini | http://mikes-mac-mini.dog-rattlesnake.ts.net:19444 | Ollama `qwen3.5:9b`, then Anthropic, then OpenAI |
| Sky | http://sky.dog-rattlesnake.ts.net:19444 | Anthropic, then OpenAI |

Connect to Tailscale first. Each dashboard has its own password in
`~/.local/share/aiops/secrets.env` on that host, named `AIOPS_DASHBOARD_PASSWORD`.
Do not copy that file into the repository. Sessions last eight hours and expire
on responder restart. The dashboard listens on loopback and the host's Tailscale
address, not its public interface. HTTP traffic between tailnet devices is carried
by Tailscale's encrypted connection; the existing public Mini Funnel is not used.

Open the live URL above, not `public/index.html` from disk. The console is optional:
investigation and recovery continue when you are signed out or have closed it.
Its password is separate from Cloudflare. To display only Mini's console password
in your own terminal:

```sh
ssh mini '/opt/homebrew/bin/node --env-file=$HOME/.local/share/aiops/secrets.env -p process.env.AIOPS_DASHBOARD_PASSWORD'
```

Mini owns incidents for Sky services. Sky owns incidents for Mini services.
Both dashboards show incident lists from both responders; selecting a peer incident
opens its owning dashboard for details and approvals. Pause and policy controls
apply to the current responder. Pause a service to suspend just its investigations.
Incoming alerts continue to be recorded while paused.

Both homepages show live status for all registered services on Mini and Sky,
with unhealthy services first and explicit unknown/stale states. Each host runs
read-only process, local endpoint and configured public endpoint checks every
30 seconds, independently of recovery and AI providers. Public checks use the
existing monitoring User-Agent. Each row shows its check time and failed checks;
samples older than 65 seconds are marked stale, including when a browser loses
contact. An unreachable peer is shown as unknown. The dashboard refreshes every
30 seconds by default, offers one- and two-minute intervals, and refreshes when
you return to its tab. The opposite host's Prometheus reads these same results
through the authenticated metrics gateway. Failures sustained for three minutes
create alerts; stale results also alert. Recovery remains subject to the existing
ownership, approval and safety rules. The registry now includes Bromley Bins and
the Kidsplorers events worker (18 applications). The worker additionally checks
its daily ingestion result, a 28-hour freshness limit and a four-hour running-job
limit. Its last observed run is retained across process restarts.

The pilot permits automatic restart and verified code restoration for six Sky
services: `top-scores`, `top-scores-web`, `top-scores-scraper`,
`top-scores-monitor`, `top-scores-audit`, and `top-scores-bsd`.
Other registered services require approval for a restart. Unknown or ambiguous
alerts receive manual triage. Shared infrastructure, host reboots, package changes,
database repairs and arbitrary shell commands are not exposed as model tools.
The initial Top Scores pilot is enabled; use the dashboard to pause it at any time.

As of the initial rollout, Ollama and Anthropic have passed live synthetic diagnosis
checks. OpenAI's configured key returns `credit_balance_exhausted`; restore the
account's credit or supply another authorized key before selecting it first.

## Alert and notification flow

```text
Existing Alertmanager ── authenticated webhook ── owning responder
        │                                            │
        └── existing Pushover notifications           ├── restricted SSH runner
                                                     ├── local incident SQLite
alerts@skynolimit.dev ── Email Worker ── host queue ────┤
        └── Gmail copy                               └── Pushover + email summary
```

The monitoring integration adds a receiver while preserving existing Pushover,
watchdog and inhibition settings. A minute-by-minute reconciliation catches active
alerts missed during responder restarts. Silenced/inhibited alerts cannot authorize
automatic recovery. The monitoring renderer preserves the optional `aiops.json`
marker on later monitoring deployments.

Pushover is the notification destination. AIOps receives the same monitoring event
directly from Alertmanager; it does not read the Pushover app's inbox. For a new
custom alert producer, send an authenticated Alertmanager-shaped event to
`/webhooks/alertmanager`, or send an alert email after Worker intake is activated.
Existing Pushover-only scripts must be connected at their producer; installing
AIOps does not automatically intercept their pushes.

Email Routing now sends `alerts@skynolimit.dev` to `aiops-alert-email`. The Worker
preserves forwarding to `mike.wagstaff@gmail.com`. A Queues Read/Write account token
is installed in each host's private environment, and both hosts authenticate to
their assigned queue. The token is account-scoped to queues, has no expiration,
and is named `AIOps alert queue consumers` in Cloudflare.

End-to-end email verification passed on 20 October 2026: a real email reached
Mini's queue, mapped to `top-scores` on Sky, and was assessed by local
`qwen3.5:9b`. The service was healthy, no recovery action was taken, cloud spend
was zero, and Pushover and SMTP accepted the summary. The original email also
arrived in Gmail. The synthetic incident retains `needs_review` because an
email-only alert has no structured source-resolution signal.

The Worker accepts only configured sender addresses for automation,
forwards other mail to Gmail, and excludes AIOps summaries to prevent loops.
It requires Cloudflare's receiving authentication result to report DMARC success
for the visible sender's domain. This supports Plunk/SES return addresses without
trusting an unauthenticated From header.
Set `ALLOWED_SENDERS` in `cloudflare/wrangler.jsonc` when onboarding a producer;
approved senders are `alerts@skynolimit.dev` and `healthchecks.io@healthchecks.io`. Use the exact registered service ID
in the subject/body. Messages naming multiple services require manual triage.
The text is untrusted evidence, never an executable instruction.

Email queues are polled every 30 seconds, persisted before acknowledgement, and
retain unconsumed messages for 24 hours. Expired mail is not automatically acted
upon. A host's queue remains assigned to that responder during an outage; this
pilot does not implement automatic leader election or move recovery ownership.

## Recovery policy and spending

The model may choose `none`, `restart`, `retry`, or `redeploy`. The runner accepts
only procedures explicitly registered by the operator. It never executes a model
supplied command, path or URL.

Automatic recovery requires an owned service, high confidence, fresh observed
failure, an allowed procedure, no pause, and a currently active source alert for
Alertmanager incidents. Restart-loop, disk, memory, certificate and shared-outage
alerts require review. The target also checks dependencies, maintenance activity,
per-project locking and a 15-minute per-service cooldown. A durable action journal
prevents replay after duplicate deliveries or uncertain crashes.

After an action, three independent health observations are made 15 seconds apart.
Local health, configured public health and source-alert state determine the result.
An action exiting successfully is not sufficient to label an incident recovered.
Summaries include attempted actions, verification, remaining problems and model
cost/reservation. Delivery failures are retained and retried up to eight times.

`redeploy` currently means **restore the verified application code snapshot and
restart the named service**. It does not fetch a new Git revision, install packages,
restore databases, remove files, or run migrations. Dependency-manifest hashes must
still match. Snapshots are created only from healthy services and checksum-verified
before writes. Refresh snapshots after an intentional application deployment.

The `retry` mechanism accepts an operator-defined argument list, but no Top Scores
job has been enabled for retries yet: a reviewed, idempotent retry entry point is
required. Normal worker restarts are available.

The default cloud allowance is $2 per incident, configurable in each dashboard.
Requests reserve a conservative input/output allowance before transmission;
successful responses reconcile against reported usage. Timeouts and unknown
billing keep their reservation. Correlated email/webhook deliveries share one
incident budget. No new model request is made after the cap would be exceeded.
Keep provider prices current when changing models. This is an application limit
for model requests, not an account-wide billing cap or a cap on hosting costs.
Investigation also limits model activity during an alert flood (20 incidents/hour).

Mini skips local inference when it is under resource pressure. Set the cloud budget
to zero to prevent cloud requests; if no suitable local model is available, evidence
is retained for manual review.

## Deployment and configuration

From the repository root:

```sh
python3 aiops/provision.py --apply
zsh deploy/node_project.zsh aiops mini --full --no-tail
zsh deploy/node_project.zsh aiops sky --full --no-tail
python3 aiops/configure-alerts.py
python3 aiops/snapshot.py
```

Provisioning creates private host state, scoped runner keys and pinned peer host
identities. It reuses existing monitoring notification credentials and available
cloud keys without printing them. Existing host configuration is preserved.
Reprovisioning rotates the shared peer token, so deploy/restart both responders
afterwards. Generated configuration initially disables automatic recovery.

Routine application updates:

```sh
zsh deploy/node_project.zsh aiops mini --quick --no-tail
zsh deploy/node_project.zsh aiops sky --quick --no-tail
```

The deploy configuration selects `/opt/homebrew/bin/node` on Mini and the private
Node 24 runtime on Sky. The application uses built-in SQLite and native TypeScript
support. `server.mjs` can bootstrap the private runtime when the system Node is
older. Mini runs as user LaunchAgent `com.aiops.api`; Sky runs as user systemd
service `com.aiops.api.service`. Mini's GUI-domain service needs that user logged in
after a reboot; it is not a pre-login system daemon.

Persistent host files under `~/.local/share/aiops/`:

| File | Purpose |
| --- | --- |
| `config.json` | Host identity, provider order/models/prices, peers, queue IDs and defaults |
| `secrets.env` | Dashboard password, webhook/peer tokens, cloud and notification credentials |
| `incidents.sqlite` | Incidents, evidence, approvals, notifications and dashboard policy overrides |
| `runner.py`, `runner.json` | Restricted executor and operator-approved procedures |
| `actions.sqlite` | Target-side action journal and cooldown history |
| `ssh/` | Dedicated restricted peer key and pinned host identities |
| `releases/` | Verified code snapshots |
| `PAUSED` or `PAUSED-<service>` | Target-side emergency stop files |

Dashboard settings override their corresponding configuration defaults. Provider
order is the order of entries in `config.json.providers`; restart the responder
after editing it. Secrets are read from the private environment file on startup.
After changing the repository's service registry or runner, reprovision the hosts
as well as deploying the application.

## Cloudflare email configuration

The account is `e40a4c949b9f4703430256d38ea7f2e3`. Existing resources:

| Queue | ID | Consumer |
| --- | --- | --- |
| `aiops-mini-alerts` | `0bec92640c1e4fd9beb5e3999c48fc21` | Mini, for Sky incidents |
| `aiops-sky-alerts` | `02755e3e0e954e3dac4bbea87d79e90c` | Sky, for Mini incidents |

Both queues have HTTP pull consumers. Worker `aiops-alert-email` has queue producer
bindings and no public HTTP endpoint.

For a fresh installation or credential replacement:

1. Create an account token with **Queues Read and Queues Write only**. Store its
   value as `CF_QUEUE_TOKEN` in each host's private `secrets.env`.
2. Add `queue: {"account": "<account above>", "id": "<host queue ID>"}` to each
   host's `config.json`, then restart the responders and verify authenticated pulls.
3. Change the Email Routing rule for `alerts@skynolimit.dev` to send to
   `aiops-alert-email`. Its Worker preserves the Gmail forward.
4. Send one clearly labelled test message from an allowed sender naming one
   registered service. Confirm Gmail forwarding, one incident, queue acknowledgement
   and the responder summary before relying on mail intake.

To publish a reviewed Worker change:

```sh
cd aiops/cloudflare
npm ci
npm test
npx wrangler deploy
```

Relevant Cloudflare contracts:
[HTTP pull consumers and authentication](https://developers.cloudflare.com/queues/configuration/pull-consumers/),
[queue retention and pricing](https://developers.cloudflare.com/queues/platform/pricing/).

## Verification and emergency controls

```sh
cd aiops
npm ci
npm run check
npm test
python3 -m unittest discover -s test -p 'test_*.py'
python3 test/live_recovery.py
```

The live test temporarily creates one disposable Sky user service, exercises the
real runner, checks recovery/idempotence/cooldown, then removes its own test files
and service. It does not restart a production service.

Initial rollout verification: 25 application tests, eight runner tests, five Worker
tests, the real disposable-service recovery test, and the focused host-runtime
deployment test passed. Monitoring tests passed with one skipped rule-tool test
because `promtool` was unavailable locally. The existing full deployment suite
has an unrelated metrics-output expectation failure in
`test_false_metrics_port_disables_monitoring_for_isolated_project`; its fixture
expects the no-metrics message while the script reports the non-Sky host skip.
Live deployments and explicit health checks succeeded on both hosts. Both hosts'
test summaries were accepted by Pushover and SMTP.

On each host, from its `~/dev/aiops` directory, run `node verify.ts` using its
configured Node binary for read-only cross-host and pilot health checks.
`node verify.ts --models` makes a small synthetic request to each configured
provider; it never executes a recovery action.

Use the dashboard's **Pause recovery** on the owning responder, or create
`~/.local/share/aiops/PAUSED` on the target host to prevent runner mutations.
An action already started cannot be undone by a later pause. Remove that file
only when ready to resume. To disable the responder through the regular deployer:

```sh
zsh deploy/node_project.zsh aiops mini --disable --no-tail
zsh deploy/node_project.zsh aiops sky --disable --no-tail
```

Retain the private state directory when redeploying. Back up SQLite with its backup
API or while the responder is stopped, rather than copying only a live database
file and omitting its WAL. Protect backups as operational data.


## Alert coverage and responder monitoring

The active cross-host platform includes the planner ingestion rules, TubeTrack
cache/push rules, Top Scores BSD upstream rules and generic `app_check_ok` rules.
Update them in `monitoring/platform/application_rules.py`, not the retired Docker
Prometheus. Full Node deploys preserve the active platform instead of rewriting
legacy monitoring. Mini's auxiliary connectivity and sleep checks are preserved
in `monitoring/platform/auxiliary-mini.json`; its legacy blackbox/textfile exporters
remain dependencies of those checks. The old Prometheus services are stopped,
with configuration and history retained.

Alertmanager explicitly sends ordinary alerts to both AIOps and Pushover.
`MonitoringWatchdog` goes only to Healthchecks.io. `AIOpsPipelineCanary` goes only
to AIOps every minute, updating a receipt timestamp without an incident or AI call.
The peer monitors this timestamp, responder availability, health-data freshness,
incident backlog, reconciliation, queue polling and undelivered notifications.
A Cloudflare scheduled Worker sends a queue canary to both responders every five
minutes. This tests Worker-to-queue-to-consumer delivery; it does not test SMTP or
DMARC. Canary metrics are never updated by reconciliation as a substitute for
actual webhook delivery. `/metrics` requires the webhook token and is proxied
through the existing peer-only metrics gateway.

Healthchecks.io sends DOWN notifications for both monitoring hosts to
`alerts@skynolimit.dev`, retaining its independent Gmail integration. Host names
in subjects map these and maintenance reports to the opposite responder for
manual host triage. Sky weekly reports now go through the alert address; successful
reports and validation messages are forwarded to Gmail without creating incidents.

Validation: `npm test` and `npm run check` in `aiops`, `npm test` in
`aiops/cloudflare`, Python runner/platform tests, and `test_rules.py` with `PROMTOOL`
set to the installed Prometheus tool. `coverage.test.json` tests the restored
application rules, AIOps failure alarms, and sustained dashboard failure/recovery.
