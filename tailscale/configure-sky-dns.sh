#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-check}"
if [[ $# -gt 1 || ( "$ACTION" != apply && "$ACTION" != check ) ]]; then
  echo "Usage: $0 [apply|check]" >&2
  exit 1
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 sky bash -s -- "$ACTION" <<'REMOTE'
set -euo pipefail
action="$1"
mini=mikes-mac-mini.dog-rattlesnake.ts.net

if [[ "$action" == apply ]]; then
  sudo -n tailscale set --accept-dns=true
fi

tailscale debug prefs | python3 -c '
import json, sys
if json.load(sys.stdin).get("CorpDNS") is not True:
    sys.exit("Tailscale DNS is disabled; run configure-sky-dns.sh apply.")
'

expected="$(tailscale ip -4 "$mini")"
for attempt in 1 2 3 4 5; do
  actual="$(getent ahostsv4 "$mini" | awk '{print $1}' | sort -u)" || actual=""
  if [[ -n "$expected" && "$actual" == "$expected" ]]; then
    break
  fi
  if [[ "$attempt" == 5 ]]; then
    echo "Mini DNS mismatch: expected $expected; resolved ${actual:-nothing}." >&2
    exit 1
  fi
  sleep 1
done

echo "$mini resolves to its Tailscale IP: $actual"
curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
  "https://$mini/train-track-planner/healthcheck"
printf '\nSky Tailscale DNS and planner HTTPS health check passed.\n'
REMOTE
