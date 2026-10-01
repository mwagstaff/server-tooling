# Tailscale configuration

## Sky DNS and the Mini planner

Sky must accept Tailscale DNS so the Mini's HTTPS hostname resolves to its
private Tailscale address instead of the public Funnel ingress. On 2026-10-01,
the public route failed with HTTPS EOF errors while the private route remained
healthy, taking down journey planning and its Prometheus scrape.

From the repository root:

```bash
./tailscale/configure-sky-dns.sh apply
./tailscale/configure-sky-dns.sh check
```

`apply` is safe to repeat: it runs `sudo -n tailscale set --accept-dns=true`
on the SSH host `sky`. `check` is read-only and is the default. Both verify the
saved preference, compare system DNS with the Mini's current Tailscale IPv4
address, and check planner HTTPS health using normal DNS and certificate
validation. Requirements on Sky: an authenticated Tailscale installation,
tailnet DNS/MagicDNS configured, Python 3, curl, getent, and (for apply)
non-interactive sudo access to `tailscale set`.

This accepts the tailnet's DNS configuration for Sky as a whole; it is not a
single-host override. The planner URL, TLS hostname, and service token stay the
same. No IP address is hard-coded and no service restart is required.

Sky's `tailscaled` systemd service stores preferences in
`/var/lib/tailscale/tailscaled.state`. They survive service and machine restarts.
That private state contains machine identity material: do not copy it into Git
or edit it manually. This script is the version-controlled desired setting.
Reapply after provisioning/authenticating a replacement Sky or if DNS preferences
are reset. It does not continuously enforce the setting.

After applying, confirm the `train-track-planner` target is `up` in Prometheus;
the `TargetDown` alert should clear on the next rule evaluation. The script's
health check does not exercise authenticated journey searches or container DNS.

To deliberately restore the previous DNS preference (which can reintroduce the
planner outage):

```bash
ssh sky 'sudo tailscale set --accept-dns=false'
```

See [Tailscale client preferences](https://tailscale.com/docs/features/client/manage-preferences).

## Tailscale Funnel installer

Quick usage

- Upload and install the helper script + service on a remote host:

```bash
./install-funnel.sh <remote-host>
```

On the Mac Mini, use `../deploy/install_mini_boot_services.zsh` instead. It installs the Funnel apply job as a reviewed system LaunchDaemon so routes are restored after boot without waiting for an interactive login. On macOS the job first kickstarts the versioned Tailscale system extension, starts the saved `Tailscale` NetworkExtension VPN service with `scutil`, waits for it to connect, and only then reapplies the Funnel routes. This ordering is required after a FileVault unlock at the login screen, where the Tailscale GUI has not launched. The generic installer above remains user-scoped on macOS.

The Mini job retries every five minutes. Its logs are:

```bash
tail -n 100 ~/Library/Logs/tailscale-funnel-apply.log
tail -n 100 ~/Library/Logs/tailscale-funnel-apply.error.log
```

Ubuntu (Oracle Cloud) note — one-time step

On Ubuntu, the `tailscale` CLI requires operator privileges to apply "serve"/"funnel" configs without `sudo`.
Run this once on the remote host to allow the installed service to apply funnel routes as your user:

```bash
sudo tailscale set --operator=$USER
```

After running that, re-run the installer (or restart the user service) to let the script apply the funnel config.

Verification

- Check the user systemd service:

```bash
systemctl --user status com.mike.tailscale-funnel-apply.service
journalctl --user -u com.mike.tailscale-funnel-apply.service --no-pager -n 200
```

- Check the logs written by the unit (if installed by the installer):

```bash
tail -n +1 /tmp/tailscale-funnel-apply.*.log
```

If you prefer the service to run as root instead, re-run `install-funnel.sh` on the installer machine and allow the sudo fallback to install a system unit.
