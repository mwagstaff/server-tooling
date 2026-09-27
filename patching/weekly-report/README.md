# Weekly upgrade reports and maintenance events

Install from the repository (requires existing Sky upgrade service, Plunk SMTP
credential, and passwordless sudo):

```bash
python3 patching/install-upgrade-report.py sky
```

This preserves the existing `server-tooling-full-upgrade.timer` schedule and
upgrade commands. It installs systemd drop-ins, so rerunning `patch_sky_host.zsh`
does not remove reporting. It does **not** run upgrades or restart cloudflared.
Existing files are backed up under `/var/backups/server-tooling/`.

## Reports

Reports go from `alerts@skynolimit.dev` to `mike.wagstaff@gmail.com` through the
existing Plunk SMTP relay with certificate-verified STARTTLS. Override the
recipient with `--email`. No new Bitwarden entry is needed. The installer makes
a root-only copy of the existing Plunk credential; rerun it after rotating that
credential. Settings live in `/etc/server-tooling/weekly-upgrade.json`.

Before an upgrade, record installed package versions. After the service ends
(including failure), compare versions and report:

- Added, upgraded, and removed packages; original upgrade service result.
- Failed system services and activity of the inventoried application services.
- Cloudflared, unattended upgrades, and weekly timer status.
- Remaining security updates and upgrades in configured APT repositories.
- Ubuntu Pro/ESM security gaps, including updates requiring coverage activation.
- Held/broken packages, required reboot, old binaries still needing restarts.
- Upgrade log and tunnel shutdown failures during that run.

Subject status is **OK**, **REVIEW**, or **FAILED**. This is an OS maintenance
assessment, not a full vulnerability scan of application dependencies or
containers or manually installed binaries. Ubuntu Pro/ESM status is checked
separately so security updates gated behind disabled coverage are highlighted;
this does not subscribe to Pro or change repositories.
The snapshot hook cannot prevent updates if it fails. An unavailable assessment
is reported as unknown/needs review, never a clean bill of health.

Reports are retained root-only for 90 days in
`/var/lib/server-tooling/weekly-upgrade/`. Undelivered email stays in `outbox/`;
`server-tooling-upgrade-report-retry.timer` retries every 15 minutes. SMTP
acceptance does not prove inbox delivery. A connection loss after acceptance
can cause a duplicate on retry; the original Message-ID is retained.

Read-only preview and one validation email (neither runs an upgrade):

```bash
ssh sky 'sudo python3 /usr/local/lib/server-tooling/report.py preview'
ssh sky 'sudo python3 /usr/local/lib/server-tooling/report.py validate'
```

Check reporting failures with:

```bash
ssh sky 'sudo journalctl -u server-tooling-full-upgrade -u server-tooling-upgrade-report-retry --since yesterday'
```

## Cloudflare Tunnel

The drop-in sets `TimeoutStopSec=40s`, leaving cloudflared's default 30-second
grace period intact. This bounds a hung shutdown that formerly waited 90 seconds.
A single connector can still cause a short outage during restart. The installer
does not force a live restart to test this. If a longer grace period is later
configured, review the systemd deadline too.

See [Cloudflare run parameters](https://developers.cloudflare.com/tunnel/reference/run-parameters/).

## Events and Grafana

Root-owned event hooks record upgrade starts/results, tunnel starts/stops, and
email acceptance/failure. One-time import reconstructs the last 30 days of
specific lifecycle messages from the journal. It never exports arbitrary logs.
The event journal and metrics are bounded to 30 days / 1,000 records.

The monitoring gateway exposes these non-secret metrics only to its existing
Tailscale peer allowlist. Both monitoring directions scrape `/events`. Fleet
overview shows an events table; all dashboards have a Host events annotation
toggle. Boot events are reconstructed independently from retained node-exporter
boot timestamps, including on macOS. Historical coverage depends on retained
evidence. Public outage histories do not retrospectively invent firings for a
newly installed rule.

Tests:

```bash
python3 -m unittest discover -s patching/weekly-report
python3 -m unittest discover -s monitoring/platform
```
