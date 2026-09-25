# Independent monitoring

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
MONITORING_REF=codex/independent-monitoring bash -c 'set -e; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL "https://raw.githubusercontent.com/mwagstaff/server-tooling/$MONITORING_REF/monitoring/bootstrap.sh" -o "$f"; bash "$f" --monitor mini --target sky'
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

Grafana is at `http://<monitor-tailscale-ip>:13000` and requires login. It is
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
unsupported metrics display no data. This is not a portable OOM-kill detector.

Redis, MongoDB, Caddy internals and scheduled-job monitoring are future modules:
add fixed exporter routes, scrape jobs and rule/dashboard groups without changing
the monitor/target roles. Existing native app metrics remain available for
app-specific rules; they do not automatically enable dependency alerting.

## Alerts

- Critical: public endpoint down for 2 minutes, runtime/host metrics unavailable
  for 3 minutes, repeated restarts, >5% HTTP errors with >=100 requests in the
  five-minute window, heap above 95%, disk below 5%, observed Linux OOM kill.
- Warning: sustained CPU/memory/I/O pressure, heap above 85%, low or rapidly
  filling disk, native metrics unavailable, certificates expiring.
- Monitoring: missing runtime targets, component/rule/notification failures.
- Critical Pushover priority is 1; warnings/recovery use 0. Emergency repeats are
  deliberately disabled. Related notifications group for 30 seconds, with
  unresolved reminders every 4 hours.

Heap/disk critical alerts inhibit their warning counterparts. A metrics gateway
failure suppresses individual runtime/native scrape alerts, while public probes
remain independent. `up=0` means metrics cannot be collected, not necessarily
that the machine is powered off. Missing inventory is checked separately.

P90/p95/p99 are calculated from HTTP histograms, excluding quiet windows with no
requests. Latency paging starts only when an explicit `latency_p95_seconds` is
set for a service after 7–14 days of representative traffic. Use
`baseline.py --host mini` to inspect observed latency and provisional thresholds;
review these before adding thresholds to inventory and reinstalling.

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
