Tailscale Funnel installer

Quick usage

- Upload and install the helper script + service on a remote host:

```bash
./install-funnel.sh <remote-host>
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
