# Monitoring and alerting

Prometheus, Grafana and Alertmanager run on `sky` from `~/monitoring`
(`docker-compose.yml`). Every deployed Node project exposes `/metrics`,
Prometheus scrapes it, alert rules turn metrics into alerts, and Alertmanager
emails them through Plunk.

```
app /metrics ──scrape──> Prometheus ──rules──> Alertmanager ──SMTP (Plunk)──> inbox
   :3018 etc.             :9090        rules/*.yml   127.0.0.1:9093           mike.wagstaff@gmail.com
```

| What | Where on `sky` | Managed by |
|---|---|---|
| Stack definition | `~/monitoring/docker-compose.yml` | `install-monitoring.zsh`, `install-alerting.zsh` (alertmanager block) |
| Scrape jobs | `~/monitoring/prometheus.yml` (one managed block per project) | `deploy/node_project.zsh` → `configure-prometheus-scrape.sh` |
| Alertmanager config | `~/monitoring/alertmanager.yml` | `install-alerting.zsh` |
| Plunk SMTP secret | `~/monitoring/secrets/plunk-smtp-password` (uid 65534, mode 400) | `install-alerting.zsh` |
| Generic alert rules | `~/monitoring/rules/_generic.yml` | `install-alerting.zsh` |
| Per-project alert rules | `~/monitoring/rules/<project>.yml` | `deploy/node_project.zsh` → `configure-prometheus-rules.sh` |
| Grafana dashboards | Grafana DB | `import-dashboards.sh` (full deploy) |

Ports 9090 (Prometheus) and 3001 (Grafana, public at
`https://api.skynolimit.dev/grafana`) are exposed by the compose file;
Alertmanager listens on `127.0.0.1:9093` only.

## Install or update Alertmanager

```bash
monitoring/install-alerting.zsh sky            # install, or re-apply config changes
monitoring/install-alerting.zsh sky --test     # ...and send a self-resolving TestAlert
monitoring/install-alerting.zsh sky --keep-secret   # rerun without Bitwarden; keeps the secret on the host
```

The script is idempotent. It reads the Plunk project secret from the Bitwarden
item `PLUNK_SECRET_KEY` in the shared deploy folder (the `Apps` field on that
item is irrelevant here; it only affects `node_project.zsh`), or from a
`PLUNK_SECRET_KEY` environment variable. Bitwarden is unlocked via the cached
session in `~/.cache/server-tooling/bitwarden-session`; when that has expired,
`bw unlock` prompts for the master password. If you only changed rules or
recipients, `--keep-secret` skips Bitwarden entirely.

Then it writes `alertmanager.yml`, `rules/_generic.yml` and the Grafana
Alertmanager datasource, upserts the `alertmanager` service and the `rules/`
mount into `docker-compose.yml`, upserts `alerting:`/`rule_files:` into
`prometheus.yml`, validates everything with `amtool` and `promtool`, then
`docker compose up -d` and reloads both services.

Settings are environment variables with these defaults:

| Variable | Default | Notes |
|---|---|---|
| `ALERT_EMAIL_TO` | `mike.wagstaff@gmail.com` | Comma-separate for several recipients |
| `ALERT_EMAIL_FROM` | `alerts@skynolimit.dev` | Must be on a domain verified in Plunk |
| `ALERT_REPEAT_INTERVAL` | `4h` | How often an unresolved alert is re-sent |
| `PLUNK_SMTP_HOST` / `PLUNK_SMTP_PORT` | `next-smtp.useplunk.com` / `2587` | STARTTLS submission port (Plunk → Settings → SMTP) |
| `PLUNK_BW_ITEM_NAME` | `PLUNK_SECRET_KEY` | Bitwarden item holding the project secret key |
| `ALERTMANAGER_HOST_PORT` | `9093` | Bound to 127.0.0.1 |

Routing lives in `alertmanager.yml` (rendered by the script, so edit the
heredoc in `install-alerting.zsh`, not the file on the host): one `email`
receiver for everything, grouped by `alertname`/`service_name`/`job`, plus a
`null` receiver for the always-firing `Watchdog`. Two inhibit rules stop
`TargetDown` from also emailing every other alert about that job, and stop a
`critical` alert from also emailing its `warning` twin. To add a second
channel later (a phone push for `severity=critical`, say), add a receiver and
a route with `matchers: ['severity = critical']` there.

## Alert rules

Rules are ordinary [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
in `~/monitoring/rules/*.yml`. Prometheus evaluates them every 15 s; `for:`
sets how long a condition must hold before the alert fires. Use labels
`severity: warning|critical` and `service_name: <app>` (the latter puts the app
name in the email subject).

### Generic rules (every app, no configuration)

`rules/_generic.yml`, installed by `install-alerting.zsh`:

| Alert | Condition | Severity |
|---|---|---|
| `TargetDown` | `up == 0` for 3 m — Prometheus cannot scrape the job | critical |
| `AppCheckFailing` | `app_check_ok == 0` for 5 m | warning |
| `AppCheckFailingLong` | `app_check_ok == 0` for 30 m | critical |
| `Watchdog` | always firing; routed to the null receiver, visible in the Alertmanager/Grafana UI as a liveness check | none |

`app_check_ok{check="<name>"}` is the cross-app convention: any service that
exports this gauge (1 healthy, 0 failing) per check gets alerts without any
per-project rules. With prom-client:

```js
new Gauge({
    name: 'app_check_ok',
    help: 'Application health checks: 1 when the named check passes, 0 when it fails',
    labelNames: ['check'],
    collect() { this.set({ check: 'live_cache_fresh' }, cacheIsFresh() ? 1 : 0); },
    registers: [register]
});
```

The email says which `service_name`, `check` and `instance` failed.

### Per-project rules

Put `observability/prometheus/rules.yml` in the project. A **full** deploy
(`node_project.zsh --full <project>`, or any Bitwarden/assets/disable deploy)
installs it as `~/monitoring/rules/<job>.yml`, where `<job>` is the scrape job
name (the project slug), and reloads Prometheus. Quick deploys skip all
Prometheus/Grafana configuration. The file is validated with `promtool` first
and the previous version is kept if validation fails. Deploys skip the step
with a warning when Alertmanager has not been installed.

To install or update rules without a full deploy:

```bash
cd /path/to/project
PROM_CONFIG_HOST=sky PROM_RULES_JOB_NAME=<job> PROM_RULES_FILE=observability/prometheus/rules.yml \
  bash /Users/mwagstaff/dev/server-tooling/monitoring/configure-prometheus-rules.sh
```

Example (`tube-track-api`): alert when `tube_track_live_cache_age_seconds`
exceeds 5 minutes (warning) or 30 minutes (critical), and when more than half
of the live refreshes in 15 minutes failed. Restrict expressions to the job
(`{job="tube-track-api"}`) so a rule cannot match another app's metric of the
same name.

To validate a rules file locally before deploying (Docker on the Mac):

```bash
docker run --rm -v "$PWD/observability/prometheus:/r:ro" --entrypoint promtool prom/prometheus:latest check rules /r/rules.yml
```

To remove a project's rules, delete `~/monitoring/rules/<job>.yml` on the host
and `curl -X POST localhost:9090/-/reload`.

## Adding a new app to monitoring

1. Expose `/metrics` (prom-client, `service_name` default label) and set
   `metrics_port` for the project in `deploy/config/node_projects.json`.
2. Make sure the service binds an address the Docker network can reach: it
   must listen on `0.0.0.0` (or the host IP), not `127.0.0.1`. ufw's default
   policy is DROP, so a public bind is still only reachable from the Docker
   subnet once step 3 is done.
3. Allow the Prometheus Docker subnet to the port. `node_project.zsh` inserts a
   raw `iptables` rule, but ufw does not persist it, so add the ufw rule too:
   ```bash
   sudo ufw allow from 172.18.0.0/16 to any port <port> proto tcp comment 'Prometheus Docker metrics'
   ```
4. Full-deploy the project: this adds the scrape job, imports dashboards and
   installs `observability/prometheus/rules.yml` if present.
5. Optionally export `app_check_ok{check=...}` for anything the generic rules
   should watch.

Check the result with `curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'`
on the host; a new job should show `health: "up"` within a minute.

## Day-to-day operation

```bash
ssh -L 9093:localhost:9093 -L 9090:localhost:9090 sky   # then http://localhost:9093 (alerts, silences) and :9090/alerts (rules)
ssh sky 'curl -s localhost:9093/api/v2/alerts | jq -r ".[] | \"\(.labels.alertname) \(.labels.job) \(.status.state)\""'
ssh sky 'docker logs --since 1h alertmanager 2>&1 | grep -i notify'   # "Notify success" or the SMTP error
```

Silence a known problem (also possible from the UI or Grafana → Alerting):

```bash
ssh sky 'curl -s -XPOST localhost:9093/api/v2/silences -H "Content-Type: application/json" -d "{
  \"matchers\":[{\"name\":\"alertname\",\"value\":\"TargetDown\",\"isRegex\":false},{\"name\":\"job\",\"value\":\"<job>\",\"isRegex\":false}],
  \"startsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"endsAt\":\"$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ)\",
  \"createdBy\":\"mike\",\"comment\":\"why\"}"'
```

Retire an app: delete its `# BEGIN <job> managed scrape config` … `# END`
block from `~/monitoring/prometheus.yml` **in place** (`cat tmp > prometheus.yml`,
never `mv` — the file is bind-mounted and a new inode is invisible to the
container), remove `rules/<job>.yml`, and reload Prometheus. A later full
deploy of that project re-adds the scrape job.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `TargetDown` for a job | Service stopped; or job is stale (retire it as above); or ufw does not allow `172.18.0.0/16` to the port; or the service binds `127.0.0.1` (`ss -ltnp` on the host); or `/metrics` is missing / not `text/plain` (`lastError` in `/api/v1/targets` says which) |
| Emails stop, `Notify attempt failed … permission denied` in Alertmanager logs | Secret file not readable by uid 65534; rerun `install-alerting.zsh sky --keep-secret` |
| `Notify attempt failed … 535` / auth errors | Plunk key rotated: rerun `install-alerting.zsh sky` (reads Bitwarden) |
| Emails bounce or never arrive, no error logged | Sender domain not verified in Plunk, or the message is in spam; send a `--test` alert and check Plunk → Activity |
| `Watchdog` missing from Alertmanager | Prometheus is not evaluating rules or cannot reach Alertmanager: `curl localhost:9090/api/v1/alertmanagers` and `/api/v1/rules` on the host |
| `install-alerting.zsh` hangs at "Unlocking Bitwarden vault" | Cached session expired; enter the master password, or use `--keep-secret` / `PLUNK_SECRET_KEY=...` |

## Current state (2026-09-21)

- Installed on `sky`; test alert and real `TargetDown` alerts delivered to
  `mike.wagstaff@gmail.com`.
- Per-project rules installed for `tube-track-api`.
- Scrape jobs removed for `kidventures-web` (retired) and `goal-guesser` (on
  hold; a full deploy re-adds it).
- `TargetDown` silenced for 7 days for `kidsplorers-web` (binds `127.0.0.1`
  because of `HOSTNAME: 127.0.0.1` in `node_projects.json`; set it to
  `0.0.0.0` and redeploy) and `sky-no-limit-web` (`server.mjs` has no
  `/metrics` route; add prom-client or set `metrics_port: false`). Both have
  never been scraped successfully.
