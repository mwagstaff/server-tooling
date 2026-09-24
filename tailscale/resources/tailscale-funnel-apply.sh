#!/bin/bash
set -euo pipefail

ensure_macos_tailscale_connected() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0

  # The macOS app stores Tailscale as a NetworkExtension VPN service. After a
  # FileVault unlock it can remain disconnected until a GUI user logs in, so
  # explicitly start the saved service from this boot-scoped LaunchDaemon.
  if ! /usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep -Fq '"Tailscale"'; then
    if [[ -d /Applications/Tailscale.app ]]; then
      echo "Saved Tailscale VPN service is not available yet" >&2
      return 1
    fi
    return 0
  fi

  local extension_label
  extension_label="$(
    /bin/launchctl print system 2>/dev/null |
      /usr/bin/awk '$3 ~ /^NetworkExtension\.io\.tailscale\.ipn\.macsys\.network-extension\./ { print $3; exit }'
  )"
  if [[ -n "$extension_label" ]]; then
    echo "Starting Tailscale system network extension..."
    /bin/launchctl kickstart "system/$extension_label"
  fi

  local status
  status="$(/usr/sbin/scutil --nc status "Tailscale" 2>/dev/null | /usr/bin/head -n 1 || true)"
  if [[ "$status" != "Connected" ]]; then
    echo "Starting saved Tailscale VPN service..."
    /usr/sbin/scutil --nc start "Tailscale"
  fi

  for _ in {1..30}; do
    status="$(/usr/sbin/scutil --nc status "Tailscale" 2>/dev/null | /usr/bin/head -n 1 || true)"
    if [[ "$status" == "Connected" ]]; then
      echo "Tailscale VPN service is connected"
      return 0
    fi
    sleep 2
  done

  echo "Tailscale VPN service did not connect within 60 seconds" >&2
  return 1
}

ensure_macos_tailscale_connected

# Resolve tailscale CLI location (launchd/systemd have minimal PATH)
TS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  # Prefer the CLI supplied by the installed macOS app so the client and
  # NetworkExtension versions match. Homebrew may contain an older CLI.
  for candidate in /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale /Applications/Tailscale.app/Contents/MacOS/tailscale /opt/homebrew/bin/tailscale; do
    if [[ -x "$candidate" ]]; then
      TS="$candidate"
      break
    fi
  done
fi
if [[ -z "$TS" ]]; then
  TS="$(command -v tailscale || true)"
fi
if [[ -z "$TS" ]]; then
  # common locations on Linux
  for candidate in /usr/local/bin/tailscale /usr/bin/tailscale /snap/bin/tailscale; do
    if [[ -x "$candidate" ]]; then
      TS="$candidate"
      break
    fi
  done
fi

if [[ -z "$TS" || ! -x "$TS" ]]; then
  echo "tailscale CLI not found" >&2
  exit 1
fi

echo "Waiting for tailscaled..."

# Wait for tailscaled to be ready (max ~60s)
for _ in {1..30}; do
  if "$TS" status >/dev/null 2>&1; then
    echo "tailscaled is ready"
    break
  fi
  sleep 2
done

# Helper: try a funnel set-path, retrying with sudo on access denied
apply_route() {
  local path="$1" url="$2"
  if "$TS" funnel --bg --yes --set-path "$path" "$url" >/dev/null 2>&1; then
    echo "Applied $path -> $url"
    return 0
  fi

  # If it failed, try with sudo if available
  if command -v sudo >/dev/null 2>&1; then
    echo "Retrying $path with sudo..."
    if sudo -n "$TS" funnel --bg --yes --set-path "$path" "$url" >/dev/null 2>&1; then
      echo "Applied (with sudo) $path -> $url"
      return 0
    fi
  fi

  echo "Failed to apply $path -> $url"
  return 1
}

echo "Applying Funnel routes..."

FAILURES=0
apply_route /grafana        http://127.0.0.1:3000/grafana || FAILURES=$((FAILURES+1))
apply_route /healthcheck    http://127.0.0.1:4000       || FAILURES=$((FAILURES+1))
apply_route /my-boris-bikes http://127.0.0.1:3010       || FAILURES=$((FAILURES+1))
apply_route /top-scores     http://127.0.0.1:3011       || FAILURES=$((FAILURES+1))
apply_route /train-track    http://127.0.0.1:3012       || FAILURES=$((FAILURES+1))
apply_route /train-track-planner http://127.0.0.1:3014 || FAILURES=$((FAILURES+1))
apply_route /bromley-bins   http://127.0.0.1:3013       || FAILURES=$((FAILURES+1))

echo "Funnel configuration status:"
# prefer non-sudo status, fall back to sudo
if ! "$TS" funnel status >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo -n "$TS" funnel status || true
  else
    echo "tailscale funnel status unavailable (need sudo or operator privileges)."
  fi
else
  "$TS" funnel status || true
fi

if [[ $FAILURES -gt 0 ]]; then
  echo "Some routes failed to apply ($FAILURES)."
  echo "If you see 'Access denied' errors, run on the host:"
  echo "  sudo tailscale set --operator=\$USER"
  echo "or run the service as root / install a system unit so tailscale runs with sufficient privileges."
fi

# Exit success so systemd user service doesn't continuously restart on non-fatal errors
exit 0
