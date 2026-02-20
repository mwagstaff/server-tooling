#!/usr/bin/env bash
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-https://api.skynolimit.dev/grafana}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:?GRAFANA_PASSWORD must be set}"

echo "==> Checking Grafana datasources..."
echo ""

# List all datasources
datasources=$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
  "$GRAFANA_URL/api/datasources" | jq -r '.[] | "\(.id)\t\(.name)\t\(.type)\t\(.access)\t\(.url)"')

echo "Current datasources:"
echo "ID  Name            Type        Access  URL"
echo "$datasources"
echo ""

# Fix each Prometheus datasource to use proxy access
echo "==> Fixing Prometheus datasources to use proxy access..."
echo ""

curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
  "$GRAFANA_URL/api/datasources" | jq -r '.[] | select(.type == "prometheus") | .id' | while read -r ds_id; do

  echo "Updating datasource ID: $ds_id"

  # Get current datasource config
  ds_config=$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$GRAFANA_URL/api/datasources/$ds_id")

  # Update to use proxy access and ensure correct URL
  updated_config=$(echo "$ds_config" | jq '. + {access: "proxy", url: "http://prometheus:9090"}')

  # Update the datasource
  response=$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    -X PUT \
    -H "Content-Type: application/json" \
    "$GRAFANA_URL/api/datasources/$ds_id" \
    -d "$updated_config")

  echo "Response: $(echo "$response" | jq -r '.message // .status // "unknown"')"
  echo ""
done

echo "==> Testing Prometheus connectivity from Grafana..."
echo ""

# Test the datasource
curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
  "$GRAFANA_URL/api/datasources" | jq -r '.[] | select(.type == "prometheus") | .uid' | while read -r ds_uid; do

  echo "Testing datasource UID: $ds_uid"

  response=$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$GRAFANA_URL/api/datasources/uid/$ds_uid/health")

  echo "Health check: $(echo "$response" | jq -r '.status // .message // .')"
  echo ""
done

echo "✅ Done! Refresh your Grafana dashboards to see if the issue is resolved."
echo ""
echo "If you still see errors:"
echo "1. Clear your browser cache"
echo "2. Hard refresh the dashboard (Ctrl+Shift+R / Cmd+Shift+R)"
echo "3. Check that dashboards are using the correct datasource"
