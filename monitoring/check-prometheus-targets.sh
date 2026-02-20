#!/usr/bin/env bash
set -euo pipefail

# Check Prometheus scrape targets status
# Usage: ./check-prometheus-targets.sh [HOST]
#   HOST: Target hostname (default: DEPLOY_HOST env var, or "ocl")

TARGET_HOST="${1:-${DEPLOY_HOST:-ocl}}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

echo "==> Checking Prometheus targets on: ${TARGET_HOST}"
echo "==> Prometheus URL: ${PROM_URL}"
echo ""

# Check if host is reachable
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${TARGET_HOST}" "exit" 2>/dev/null; then
  echo "Error: Cannot connect to ${TARGET_HOST}" >&2
  exit 1
fi

# Check if Prometheus is running
if ! ssh "${TARGET_HOST}" "curl -s -f ${PROM_URL}/api/v1/status/config >/dev/null 2>&1"; then
  echo "Error: Prometheus is not responding at ${PROM_URL}" >&2
  echo "Hint: Check if Prometheus container is running with: ssh ${TARGET_HOST} 'sudo docker ps | grep prometheus'" >&2
  exit 1
fi

# Fetch and display targets
echo "Active targets:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ssh "${TARGET_HOST}" "curl -s '${PROM_URL}/api/v1/targets'" | jq -r '
  .data.activeTargets[] |
  {
    job: .labels.job,
    instance: .labels.instance,
    health: .health,
    lastScrape: .lastScrape,
    lastError: .lastError
  } |
  "Job: \(.job)\n  Instance: \(.instance)\n  Health: \(.health)\n  Last Scrape: \(.lastScrape // "never")\n  Last Error: \(.lastError // "none")\n"
'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Summary statistics
summary=$(ssh "${TARGET_HOST}" "curl -s '${PROM_URL}/api/v1/targets'" | jq -r '
  .data.activeTargets |
  group_by(.health) |
  map({health: .[0].health, count: length}) |
  .[] |
  "  \(.health): \(.count)"
')

echo ""
echo "Summary:"
echo "${summary}"

# Exit with error if any targets are down
down_count=$(ssh "${TARGET_HOST}" "curl -s '${PROM_URL}/api/v1/targets'" | jq -r '
  .data.activeTargets |
  map(select(.health == "down")) |
  length
')

if [[ "${down_count}" -gt 0 ]]; then
  echo ""
  echo "⚠️  Warning: ${down_count} target(s) are down" >&2
  exit 1
fi

echo ""
echo "✅ All targets are healthy"