#!/bin/bash
set -euo pipefail

# Resolve tailscale CLI location (launchd/systemd have minimal PATH)
TS="$(command -v tailscale || true)"
if [[ -z "$TS" ]]; then
  # common locations on macOS and Linux
  for candidate in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /usr/bin/tailscale /snap/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale /Applications/Tailscale.app/Contents/MacOS/tailscale; do
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
    if sudo "$TS" funnel --bg --yes --set-path "$path" "$url" >/dev/null 2>&1; then
      echo "Applied (with sudo) $path -> $url"
      return 0
    fi
  fi

  echo "Failed to apply $path -> $url"
  return 1
}

echo "Applying Funnel routes..."

FAILURES=0
apply_route /grafana        http://127.0.0.1:3001/grafana || FAILURES=$((FAILURES+1))
apply_route /healthcheck    http://127.0.0.1:4000       || FAILURES=$((FAILURES+1))
apply_route /my-boris-bikes http://127.0.0.1:3010       || FAILURES=$((FAILURES+1))
apply_route /top-scores     http://127.0.0.1:3011       || FAILURES=$((FAILURES+1))
apply_route /train-track    http://127.0.0.1:3012       || FAILURES=$((FAILURES+1))
apply_route /bromley-bins   http://127.0.0.1:3013       || FAILURES=$((FAILURES+1))

echo "Funnel configuration status:"
# prefer non-sudo status, fall back to sudo
if ! "$TS" funnel status >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo "$TS" funnel status || true
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
