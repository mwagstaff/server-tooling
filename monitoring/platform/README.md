# Independent monitoring

For adding services or alert rules, start with the
[alerting and AIOps integration guide](../ALERTING.md). It defines the maintained
configuration sources, target labels, recovery-policy review and delivery checks.

Prometheus, Grafana, Alertmanager and Blackbox Exporter on one host monitor
another host directly over Tailscale. Pushover receives grouped warning,
critical and recovery notifications. Optional Healthchecks.io watchdogs check
the Prometheus → Alertmanager → external receiver path.

## Install

From a checkout on your deployment machine:

```bash
bash monitoring/install.sh --monitor mini --target sky
# Reverse direction:
bash monitoring/install.sh --monitor sky --target mini
```

GitHub bootstrap (run from a machine with SSH access to both hosts):

```bash
MONITORING_REF=main bash -c 'set -e; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL "https://raw.githubusercontent.com/mwagstaff/server-tooling/$MONITORING_REF/monitoring/bootstrap.sh" -o "$f"; bash "$f" --monitor mini --target sky'
```

For repeatable installation, set `MONITORING_REF` in the command to a reviewed
commit (both downloads then use that commit). Release binaries are
versioned in `host.py` and verified against upstream SHA-256 checksums.

Prerequisites: Python 3.12+ locally and on hosts, SSH aliases, authenticated
Tailscale on both hosts, an unlocked Bitwarden CLI session on the deployment
machine, Homebrew on macOS, and Docker on a Linux monitor for Grafana.
Native Prometheus/exporter binaries run through launchd or user systemd. Linux
user lingering is enabled for startup at boot. Existing monitoring installations
are retained during migration; these services use separate ports and storage.

On macOS the installer starts user services and stages this one-time administrator
step, which must be run interactively on the Mac (or through `ssh -t mini`):

```bash
~/.local/share/server-tooling-monitoring/enable-boot.sh
```

This registers reviewed LaunchDaemons running as the installing user. A password
is required by macOS; no broad passwordless sudo rule is installed. It does not
bypass FileVault's boot unlock or change sleep settings. Boot recovery should be
checked during a planned reboot after the migration.

## Credentials

Use the existing deploy folder in Bitwarden. Set the `Apps` custom field to
`monitoring` for these exact entry names:

| Entry | Required |
| --- | --- |
| `PUSHOVER_USER_KEY` | Yes |
| `PUSHOVER_API_KEY_MONITORING` | Yes |
| `HEALTHCHECKS_PING_URL_MINI` | To enable Mini's watchdog |
| `HEALTHCHECKS_PING_URL_SKY` | To enable Sky's watchdog |

The value follows the existing convention: first non-Apps custom field, or login
password. Grafana uses the existing `GRAFANA_PASSWORD` login password (legacy
`GRAFANA_LOGIN` is also supported; username
`admin`). Secrets are transferred using SSH, stored with mode 600, and excluded
from the repository. Notification credentials are installed on the monitoring
host only. Journey Planner's authenticated native metrics additionally use its
existing `PLANNER_SERVICE_TOKEN` on the target.

After adding a watchdog URL or rotating secrets, rerun with `--skip-target`.
Use `--keep-secrets` for configuration-only updates without accessing Bitwarden.

## Private access

The metrics gateway binds only the target's Tailscale IPv4 address, port 19443,
and accepts only the configured monitor's IPv4 address. It exposes fixed metric
paths, rejects redirects and arbitrary upstream URLs, and forwards only to
allowlisted loopback endpoints. Applications keep their existing listeners.
Tailscale encrypts the connection. Restrict access further in tailnet policy if
other users share the network.

Grafana uses the monitor's Tailscale DNS hostname and requires login:

- Mini monitoring Sky: <http://mikes-mac-mini.dog-rattlesnake.ts.net:13000/dashboards>
- Sky monitoring Mini: <http://sky.dog-rattlesnake.ts.net:13000/dashboards>

Connect the viewing device to Tailscale. The installer discovers these hostnames
and uses them for Grafana's root URL and Pushover dashboard links, while private
listeners and scraper access controls remain bound to Tailscale IPs. Grafana is
reachable independently of the monitored server. Prometheus (19090), Alertmanager
(19093), Blackbox Exporter (19115), Node Exporter (19100) and Node adapters
(19200 onwards) bind to loopback.

## Coverage and inventory

`inventory.json` describes each host's services, startup wrapper, entry point,
native metrics path, runtime port and public URL. Every service gets separate
runtime and scrape identities. Add another host and its services there; reuse
the installer with that SSH alias. Keep runtime ports unique on each host.
Only one authoritative monitor per target is supported by the gateway allowlist.

Four dashboards are provisioned: fleet overview, service health, host health,
and monitoring health. The default is 15-second scrapes and 30-day retention,
with a 5 GB Prometheus data retention cap. Allow extra disk space for the WAL,
head block, logs and Grafana; the retention cap is not a filesystem quota.

The dependency-free Node preload exports process CPU/RSS, V8 heap usage and its
actual limit, external memory, GC duration, event-loop delay and HTTP histograms.
The installer adds an opt-in hook to each managed startup wrapper and restarts
services one at a time. The deployer's quick and full wrappers retain this hook.
Metrics bind only to loopback. Service and HTTP status labels are bounded; raw
URLs, query strings and user identifiers are never captured by the adapter.

HTTP instrumentation covers Node HTTP/HTTPS server responses, including aborted
responses, and excludes `/metrics` and common health routes. It does not capture
HTTP/2, WebSocket traffic or requests rejected upstream by Cloudflare/Caddy.
Public probes cover availability through that upstream path. Heap and event-loop
metrics describe the main V8 isolate; worker-thread heaps need app-specific
metrics. RSS/CPU describe the process. Short spikes between scrapes may be missed.

Linux and macOS expose different host metrics. Linux memory pressure, I/O wait
and OOM rules use Linux kernel measurements. macOS has separate memory panels
and a low-free/inactive-memory alert gated by sustained swap-out;
host dashboards select the memory panel for the target OS and use only the host
exporter, avoiding duplicate application-exported host metrics. This is not a
portable OOM-kill detector.

Redis, MongoDB, Caddy internals and scheduled-job monitoring are future modules:
add fixed exporter routes, scrape jobs and rule/dashboard groups without changing
the monitor/target roles. Existing native app metrics remain available for
app-specific rules; they do not automatically enable dependency alerting.

## Alerts

- Critical: shared public outage for 45 seconds (at least two services),
  individual public endpoint down for 2 minutes, runtime/host metrics unavailable
  for 3 minutes, repeated restarts, >5% HTTP errors with >=100 requests in the
  five-minute window, heap above 95%, disk below 5%, observed Linux OOM kill.
- Warning: sustained CPU/memory/I/O pressure, heap above 85%, low or rapidly
  filling disk, native metrics unavailable, certificates expiring.
- Monitoring: missing runtime targets, component/rule/notification failures.
- Critical Pushover priority is 1; warnings/recovery use 0. Emergency repeats are
  deliberately disabled. Related notifications group for 30 seconds (shared
  outages notify immediately after firing), with
  unresolved reminders every 4 hours.

Heap/disk critical alerts inhibit their warning counterparts. A metrics gateway
failure suppresses individual runtime/native scrape alerts, while public probes
remain independent. `up=0` means metrics cannot be collected, not necessarily
that the machine is powered off. Missing inventory is checked separately.

### Mini sleep metrics collector

Mini's auxiliary `aux-node-2` job scrapes the Homebrew node exporter on
`127.0.0.1:9100`. It is separate from the managed host exporter on port 19100.
The `sh.brew.node_exporter` user LaunchAgent reads
`/opt/homebrew/etc/node_exporter.args`, which enables the textfile collector at
`/opt/homebrew/var/lib/node_exporter/textfile`. The `com.mike.sleep-metrics`
LaunchAgent updates `mac_sleep.prom` there every minute. Keep both agents when
retiring legacy monitoring services: the `MacSleptRecently` and
`SleepSettingReverted` rules depend on these metrics.

If `mini node collector unavailable` fires, check port 9100 and
`launchctl print user/$(id -u)/sh.brew.node_exporter` on Mini. A saved copy of
the agent is at
`~/.local/share/server-tooling/retired-launchagents-20261021/sh.brew.node_exporter.plist`.
Restore it to `~/Library/LaunchAgents/` and bootstrap it in the user domain if
the agent is missing. Verify `node_textfile_scrape_error == 0` at the exporter
endpoint, then `up{job="aux-node-2"} == 1` and the presence of
`mac_sleep_events_24h` and `mac_pmset_setting{name="sleep"}` in Mini's active
Prometheus. The exporter alert detects failed scrapes; it does not detect a stale
or missing textfile while the exporter itself remains reachable.

P90/p95/p99 are calculated from HTTP histograms, excluding quiet windows with no
requests. Latency paging starts only when an explicit `latency_p95_seconds` is
set for a service after 7–14 days of representative traffic. Use
`baseline.py --host mini` to inspect observed latency and provisional thresholds;
review these before adding thresholds to inventory and reinstalling.

## Alert history and host events

Fleet overview includes one row per observed alert episode, including failures
that recover while still **Pending**. It shows Started at, Fired at (blank when
never fired), summary, current status and last observed failure. Pending and
firing samples are joined so a continuing failure is not counted twice.
**Recovered (brief)** means the notification threshold was never reached;
**Resolved** means a previously firing alert has cleared. A firing timestamp
does not guarantee delivery: routing, inhibition and delivery failures also
apply. Status is checked now even when viewing an earlier period.

History uses retained Prometheus samples, up to 30 days subject to the 5 GB cap.
Times have roughly 15-second precision; collection gaps can split episodes.
Summaries use current rule templates. Watchdog alerts are excluded. The existing
metrics gateway serves history on loopback port 19116; Grafana's pinned Infinity
plugin reads it through a provisioned data source. There is no extra public port
or event database. Errors are shown instead of stale recovery status when
Prometheus is unavailable.

A separate **Host events** table and graph annotations show weekly upgrades,
tunnel lifecycle events and host reboots. Reboots derive from retained boot
metrics. Use the [host maintenance installer](../../patching/README.md) for
weekly upgrades, email reports, maintenance events and scheduled host reboots. Host filters apply to events;
service filters intentionally do not hide host-wide maintenance. Annotation
queries follow the [Infinity annotation format](https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/annotations/).

**SharedPublicOutage** fires when at least two public services on the same host
fail continuously for 45 seconds. Its Alertmanager route has no extra group wait;
allow up to two 15-second scrape/evaluation intervals before notification.
It inhibits individual PublicEndpointUnavailable notifications for that host
while active; those individual rules retain their two-minute threshold. Hosts
with only one public endpoint retain individual endpoint alerting.

## External watchdog

Create `monitoring-mini` and `monitoring-sky` in Healthchecks.io, each with a
one-minute period and a three-minute grace period. Connect the Pushover
integration there, and save their ping URLs in Bitwarden as above. The always
firing Watchdog rule is repeated to the check's webhook every minute. Resolved
watchdog notifications are disabled. Missing credentials leave this route silent
and the installer explicitly reports the watchdog as pending.

This uses two of the free tier's 20 jobs. The 100 log entries per job are a
rolling history, not a heartbeat quota. These checks detect loss of the alerting
chain; they do not prove Pushover delivery or that every individual scrape works.

## Verify and operate

```bash
python3 -m unittest discover -s monitoring/platform -p 'test_*.py' -v
# Set PROMTOOL=/path/to/promtool to also run the alert and histogram scenarios.
python3 monitoring/platform/verify.py --host mini
python3 monitoring/platform/verify.py --host mini --test-alert
```

Deployment and `verify.py` both check that all four dashboards are provisioned,
the monitoring data sources exist, and Grafana can query live Prometheus data
and execute the alert-history table through its actual backend data source.
Linux Docker path overrides explicitly point provisioning and persistent data at
the monitoring directory. Upgrading the original container first stops it and
backs up its database before migrating to persistent storage.

The test alert sends a self-resolving Pushover notification. Do not retire legacy
alerts until all expected targets are up and firing/recovery notifications have
been confirmed. Test failures using a disposable HTTP fixture, never by exhausting
production heap or disk. Runtime start timestamps detect sampled restarts.

Files and data live in `~/.local/share/server-tooling-monitoring`. Previous
configuration files and original app wrappers are retained in `backups/`. To
disable instrumentation, remove that service wrapper's `.monitoring.sh` sidecar
and restart the service; the original application command stays intact.
To restore a configuration, copy the selected backup's files over their matching
paths and restart the corresponding monitoring services. Secrets and historical
data are retained. No automatic destructive uninstall is provided.

Mac logs are in `logs/`; Linux logs use the user journal:

```bash
journalctl --user -u com.server-tooling.monitoring.prometheus.service
```

The original `monitoring/install-monitoring.zsh` and `install-alerting.zsh` still
manage the legacy Sky stack. They must not be used to update this independent
platform. Legacy email alerts may coexist during the migration.

## Diagnosing brief scrape failures

The gateway logs structured warnings for upstream failures, responses larger than
8 MiB, downstream disconnects, and successful responses taking at least two seconds.
Each warning includes the allowlisted route, stage, elapsed milliseconds, upstream
HTTP status when available, response bytes, and exception/OS error codes. It never
logs credentials, upstream URLs, raw exception messages, headers, or response bodies.
Normal successful scrapes remain quiet. Timestamps are UTC.

On Sky, inspect `journalctl --user -u com.server-tooling.monitoring.gateway.service`.
On Mini, gateway warnings are in
`~/.local/share/server-tooling-monitoring/logs/gateway.log`.

Prometheus also records failed scrapes in
`~/.local/share/server-tooling-monitoring/logs/scrape-failures.log` on the monitoring
host (Mini for Sky). This captures transport, HTTP and metrics parsing errors even
when the gateway responds successfully. Correlate the timestamp and target with
the gateway route; the dashboard alert timestamp may be one evaluation later.
These logs are separate from the 30-day metrics retention. When rotating the
scrape-failure file, send Prometheus SIGHUP to reopen it. Avoid adding credentials
or sensitive query parameters to scrape URLs, since Prometheus logs targets.


## Central logs and incident troubleshooting

`python3 monitoring/platform/install_logs.py` installs pinned Loki 3.7.9 on Mini
and Alloy 1.21.2 on both hosts. Run `install.py` afterwards in both monitoring
directions with `--skip-target --keep-secrets` to provision log health scrapes,
alerts and the `monitoring-loki` datasource. Reuse the existing LOKI_TOKEN; never
paste it into URLs. `configure_log_dashboards.py` also integrates the existing
Sky public Grafana and places the website dashboard in its web folder.

Loki binds only loopback (13100/13109). Its gateway on Mini Tailscale port 13101
requires Basic authentication and an allowed peer IP, permits queries/push only,
and limits request/response size. Grafana and AIOps query server-side. The store
uses filesystem TSDB with 14-day retention, 0.1 MB/s ingestion limit, bounded
queries and memory targets. Mini is the single storage node; this is not HA.
Sky Alloy is a system service running as mwagstaff with journal read access.
Mini initially installs login LaunchAgents. Promote the four logging services
to system LaunchDaemons with the scoped command below; they continue running as
the installation owner. Administrator authentication is required once. The
installer then preserves system service management on subsequent updates. Alloy's disk WAL currently requires its experimental stability flag;
replay is bounded by the pinned release's default one-hour segment age.

Registered application files, AIOps files and Sky service journals are collected.
File tails begin at collection time and carry `timestamp_source=collected`:
they must not be treated as historic event timestamps. Journals retain event
timestamps. New files are rediscovered every 10 seconds. Filters redact
credential-bearing text, URLs, email addresses, common token formats and PEM
markers/base64 lines; arbitrary application text is not a guarantee of PII-free
logging. Request bodies and headers are never intentionally exported.

`configure_access_logs.py --apply` on Sky validates/backups/reloads Caddy's
existing listener to enable sanitized access logs and a generated request ID.
Queries, client addresses and headers are excluded. The shared Node runtime
records completion status, duration, path without query, request ID and probe
flag. It is active on Kidsplorers web now; other processes load it on their next
planned restart. Do not restart active workers just to enable request logging.

Use Grafana's Service Logs dashboard with host/service and the alert's absolute
time window; Explore supports LogQL, for example
`{host="sky",service="kidsplorers-web"} |= "request_id"`.
Filter by a particular request ID to join Caddy and Node evidence. AIOps emails
link directly to service metrics, host metrics and logs with a fixed incident
window. Untimestamped/stale evidence lowers confidence and forces the next
configured provider subject to the existing $2 incident limit. No new automatic
recovery permission is granted.

HttpErrors now measures only 5xx. HttpAbortedRequests separately measures aborted
connections. Both require over 5% for 5 minutes and at least 100 requests in the
five-minute window. Inspect status counts, request logs and probe flags before
assuming a service outage. HTTP health probes must drain responses to avoid
creating aborted requests themselves.

Each host emits an ingested canary every minute. LogCollectorUnavailable,
LogPipelineStalled, LogEntriesDropped and LogStorageSpaceLow cover scrape loss,
stale ingestion, dropped entries and less than 10 GiB free. Check `/metrics` on
loopback 13102 and Alloy on 12345; the existing private metrics gateway exports
them. Retention is configured, not a claim of 14 days of existing history.

For rollback, stop Alloy/canary and Mini Loki/gateway using their service manager;
restore the timestamped Caddyfile backup and validate before reload. Remove the
logging.json marker and regenerate monitoring config to remove log scrapes and
alerts. Preserve data/loki and data/alloy until retention/rollback needs are clear.


### Enable Mini log services at boot

After installing logs, run from an interactive terminal:

```sh
ssh -t mini '~/.local/share/server-tooling-monitoring/enable-boot.sh --services loki log-gateway alloy log-canary'
```

This installs root-owned LaunchDaemons with RunAtLoad/KeepAlive and the existing
unprivileged service user. It preflights all four definitions, starts them in the
system domain, and retires their login plists to prevent duplicate processes.
It does not restart the other monitoring services or reboot the host. If a
bootstrap fails, it attempts to restore that service's previous launch domain.
For later binary argument changes, rerun the same command to apply staged plists.
Check `launchctl print system/com.server-tooling.monitoring.loki` and the other
three labels, then verify both log canaries through Sky's Prometheus. A reboot
remains a separate operational test; system registration alone is not a reboot test.

The collector limits processing to 50 lines/second with a 100-line burst using
backpressure (`drop = false`), so ordinary bursts wait instead of being discarded.
Watch the ingestion canary for excessive processing lag.


Notification/rule-failure alerts require failures in a rolling two-minute window
continuously for five minutes. This rejects isolated recovered deployment failures;
canaries/backlog checks still cover stalled delivery. Required logging and AIOps
telemetry has explicit missing-data alerts, in addition to scrape availability.
See the infrastructure coverage audit in `aiops/README.md` for diagnosis scope.

### Planned versus unexpected restarts

Deployment maintenance now marks one upcoming runtime start per selected service.
`RestartLoop` counts three unexpected starts within 15 minutes using persisted
`monitoring_unplanned_restarts_15m`; planned deploy starts do not accumulate after
the three-minute silence expires. A subsequent crash consumes no further credit.
Older runtimes and accounting failures retain the process-start fallback. The
updated preload activates at the next service start, with a fresh baseline on
first activation. See `../ALERTING.md` for marker expiry and state limitations.
