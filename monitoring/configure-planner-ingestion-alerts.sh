#!/usr/bin/env bash
set -euo pipefail

# Sky Prometheus scrapes Mini's authenticated planner metrics via the existing
# HTTPS Funnel route. The token comes from Sky's already-provisioned gateway
# secret; only a raw, group-restricted copy is mounted in Prometheus.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_HOST="${1:-sky}"

ssh -o BatchMode=yes "$MONITOR_HOST" bash -s <<'REMOTE'
set -euo pipefail
monitoring_dir="$HOME/monitoring"
config="$monitoring_dir/prometheus.yml"
compose="$monitoring_dir/docker-compose.yml"
registry="$HOME/.local/share/train-track-api/planner-targets.json"
gateway_env="$HOME/dev/train-track-api/.bw-secrets.env.sh"
token_file="$monitoring_dir/secrets/train-track-planner-token"
mount='./secrets/train-track-planner-token:/etc/prometheus/secrets/train-track-planner-token:ro'
begin='# BEGIN train-track-planner managed scrape config'
end='# END train-track-planner managed scrape config'
test -f "$config" && test -f "$compose" && test -f "$registry" && test -f "$gateway_env"
base_url="$(jq -r '.targets[] | select(.id == "mini") | .baseUrl' "$registry")"
if [[ ! "$base_url" =~ ^https://([A-Za-z0-9.-]+)(/[A-Za-z0-9/_-]+)$ ]]; then
  echo 'Error: Mini target URL is missing or unsafe for a Prometheus scrape.' >&2
  exit 1
fi
target="${BASH_REMATCH[1]}"
metrics_path="${BASH_REMATCH[2]}/internal/planner/metrics"
(
  set -a
  source "$gateway_env"
  set +a
  token="${PLANNER_MINI_SERVICE_TOKEN:-}"
  if [[ -z "$token" ]]; then
    echo 'Error: Sky gateway has no Mini service token.' >&2
    exit 1
  fi
  if ! curl -fsS --max-time 10 -H "Authorization: Bearer $token" \
    "$base_url/internal/planner/metrics" | grep '^timetable_ingestion_last_result' >/dev/null; then
    echo 'Error: Sky cannot read authenticated Mini ingestion metrics.' >&2
    exit 1
  fi
  umask 077
  mkdir -p "$monitoring_dir/secrets"
  if [[ ! -e "$token_file" ]]; then install -m 600 /dev/null "$token_file"; fi
  printf '%s' "$token" > "$token_file"
  sudo -n chgrp 65534 "$token_file"
  chmod 640 "$token_file"
)

candidate_compose="$(mktemp "$monitoring_dir/.planner-compose.XXXXXX")"
candidate_config="$(mktemp "$monitoring_dir/.planner-prometheus.XXXXXX")"
trap 'rm -f "$candidate_compose" "$candidate_config"' EXIT
if grep -Fq "$mount" "$compose"; then
  cp "$compose" "$candidate_compose"
else
  awk '{ print } /^      - \.\/rules:\/etc\/prometheus\/rules:ro[[:space:]]*$/ { print "      - ./secrets/train-track-planner-token:/etc/prometheus/secrets/train-track-planner-token:ro" }' \
    "$compose" > "$candidate_compose"
  if ! grep -Fq "$mount" "$candidate_compose"; then
    echo 'Error: Prometheus rules mount not found in Compose configuration.' >&2
    exit 1
  fi
fi

awk -v begin="$begin" -v end="$end" '
  $0 == begin { skip = 1; next }
  skip && $0 == end { skip = 0; next }
  !skip { print }
' "$config" > "$candidate_config"
grep -q '^scrape_configs:' "$candidate_config" || { echo 'Error: scrape_configs is missing.' >&2; exit 1; }
cat >> "$candidate_config" <<SCRAPE
$begin
  - job_name: 'train-track-planner'
    scheme: https
    metrics_path: '$metrics_path'
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/secrets/train-track-planner-token
    static_configs:
      - targets: ['$target']
$end
SCRAPE
chmod 644 "$candidate_config"
docker compose -f "$candidate_compose" config -q
docker run --rm -v "$candidate_config:/etc/prometheus/prometheus.yml:ro" \
  -v "$monitoring_dir/rules:/etc/prometheus/rules:ro" \
  -v "$token_file:/etc/prometheus/secrets/train-track-planner-token:ro" \
  --entrypoint promtool prom/prometheus:latest check config /etc/prometheus/prometheus.yml
test -f "$monitoring_dir/docker-compose.yml.before-planner-ingestion" || cp -p "$compose" "$monitoring_dir/docker-compose.yml.before-planner-ingestion"
test -f "$monitoring_dir/prometheus.yml.before-planner-ingestion" || cp -p "$config" "$monitoring_dir/prometheus.yml.before-planner-ingestion"
cat "$candidate_compose" > "$compose"
# prometheus.yml is a single-file bind mount: keep its inode when updating.
cat "$candidate_config" > "$config"
docker compose -f "$compose" up -d --no-deps prometheus
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null
echo "Configured authenticated Mini scrape as train-track-planner on $target"
REMOTE

PROM_CONFIG_HOST="$MONITOR_HOST" PROM_RULES_JOB_NAME=train-track-planner \
  PROM_RULES_FILE="$SCRIPT_DIR/rules/train-track-planner.yml" \
  bash "$SCRIPT_DIR/configure-prometheus-rules.sh"

ssh -o BatchMode=yes "$MONITOR_HOST" bash -s <<'VERIFY'
set -euo pipefail
for attempt in 1 2 3 4 5 6 7 8; do
  health="$(curl -fsS --max-time 5 http://127.0.0.1:9090/api/v1/targets | jq -r '[.data.activeTargets[] | select(.labels.job == "train-track-planner") | .health][0] // "missing"')"
  [[ "$health" == up ]] && break
  sleep 4
done
[[ "$health" == up ]] || { echo "Error: Mini scrape is $health; inspect Prometheus target diagnostics." >&2; exit 1; }
count="$(curl -fsS --max-time 5 http://127.0.0.1:9090/api/v1/rules | jq '[.data.groups[] | select(.file | endswith("/train-track-planner.yml")) | .rules | length] | add // 0')"
[[ "$count" -ge 5 ]] || { echo "Error: only $count planner alert rules are loaded." >&2; exit 1; }
echo "Mini scrape is up; $count timetable alert rules are loaded on Sky."
VERIFY
