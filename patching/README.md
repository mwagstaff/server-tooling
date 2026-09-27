# Host maintenance

Install from your laptop/controller onto an Ubuntu host over SSH. This is
independent of the monitoring installer: no Tailscale or monitoring inventory is
required. Tested on Ubuntu 24.04 with systemd, Python 3, and passwordless sudo.
The controller needs Python 3, SSH/SCP, curl and tar; for a new host, an unlocked
Bitwarden CLI session (the normal server-tooling cached session also works).

## One-line install

While PR #1 is awaiting merge, use the published branch:

```bash
MAINTENANCE_REF=codex/independent-monitoring bash -c 'set -e; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL "https://raw.githubusercontent.com/mwagstaff/server-tooling/$MAINTENANCE_REF/patching/bootstrap.sh" -o "$f"; bash "$f" new-host'
```

Replace `new-host` with an SSH alias or `user@hostname`. After merge, use `main`
instead of `codex/independent-monitoring`. A Git commit SHA can be used to pin the
installer. From a checkout, the equivalent is:

```bash
python3 patching/install-maintenance.py new-host
```

Optional flags: `--email you@example.com`, `--from-email alerts@your-verified-domain`,
`--user-unit my-app.service` (repeat for each service belonging to the SSH user),
`--skip-caddy` (for custom Caddy builds or separately managed packages).
Known hosts use their application units from the monitoring inventory by default.
Unlisted hosts still get system, package and security checks; add user service
names to include individual application status. This does not install applications
or the Grafana/Prometheus stack; see [monitoring](../monitoring/README.md) for that.

## What it configures

- Daily unattended Ubuntu security updates, including enabled ESM coverage.
- Weekly full APT upgrade, default Sunday 04:00 **UTC**, with up to 20 minutes
  of jitter. Existing upgrade script and timer are preserved on reruns.
- Gmail-friendly HTML upgrade reports, plain-text fallback and diagnostic attachment.
- Standard APT-installed Caddy: signed official stable repository, isolated package
  pinning and configuration preflight before every update. The installer validates
  and installs the current release; Caddy may briefly restart. Daily updates then
  keep it current. Custom builds should use `--skip-caddy`.
- Existing cloudflared service: shutdown bounded to 40 seconds with event hooks.
- Weekly reboot **Saturday 04:00 Europe/London**, automatically following BST/GMT.
  The installer enables only the timer; it does not reboot the host.

Automatic update-triggered reboots are disabled so that the Saturday timer owns
reboots. Updates that need a reboot may wait until Saturday to become fully
active; the report highlights outstanding restarts. Saturday is before the
Sunday upgrade, so a Sunday kernel update can wait six days unless you reboot
manually. You can still perform an urgent manual restart at any time.

An active package install delays the scheduled reboot for up to 30 minutes. If it
remains busy, or a shutdown inhibitor blocks the reboot, the service fails and
records an event rather than interrupting the transaction. Failed system units
are included in the weekly report. A missed weekly reboot is **not** replayed on
boot (`Persistent=false`). Reboot requests/failures are recorded in the existing
host event journal; actual boot annotations come from node-exporter when monitored.

## Secrets and reports

Defaults: `alerts@skynolimit.dev` → `mike.wagstaff@gmail.com`, using Plunk STARTTLS.
A new host retrieves `PLUNK_SECRET_KEY` from the existing Bitwarden deploy folder;
no new secret or Apps association is needed. Existing root report credentials or
legacy monitoring Plunk credentials are reused. `PLUNK_SECRET_KEY` supplied in
the controller environment explicitly replaces the deployed credential, useful
for rotation. Credentials travel over encrypted SSH and are stored root-only;
they are never included in the command line. Other SMTP settings are in
`/etc/server-tooling/weekly-upgrade.json`.

The installer is safe to rerun and backs up changed files under
`/var/backups/server-tooling/`. It does not launch a full upgrade or a validation
email. See [report details](weekly-report/README.md) for validation, troubleshooting
and Caddy rollback backups.

## Verify / disable weekly reboot

```bash
ssh new-host 'systemctl list-timers "server-tooling-*" --no-pager'
ssh new-host 'sudo python3 /usr/local/lib/server-tooling/report.py preview'
ssh new-host 'sudo systemctl disable --now server-tooling-weekly-reboot.timer'
```

Disabling the reboot timer leaves daily security updates and weekly upgrades
running. It does not re-enable unattended update-triggered reboots.

Tests (no host restarts):

```bash
python3 -m unittest discover -s patching -p 'test_*.py'
python3 -m unittest discover -s patching/weekly-report -p 'test_*.py'
```
