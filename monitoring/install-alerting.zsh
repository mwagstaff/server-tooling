#!/usr/bin/env zsh
set -euo pipefail

# Installs Prometheus Alertmanager next to the existing Prometheus + Grafana
# stack (see install-monitoring.zsh) and wires it to send email through Plunk's
# SMTP relay. Idempotent: rerun to update the SMTP secret, recipients or the
# generic rule set.
#
# Layout on the host (REMOTE_DIR, default ~/monitoring):
#   docker-compose.yml         alertmanager service upserted in a managed block
#   prometheus.yml             alerting/rule_files upserted in a managed block
#   alertmanager.yml           route everything to one email receiver
#   rules/_generic.yml         alerts that apply to every scraped job
#   rules/<project>.yml        per-project rules (deploy/node_project.zsh)
#   secrets/plunk-smtp-password  Plunk project secret key, owned by uid 65534, mode 400
#
# The Plunk key is read from the Bitwarden item named PLUNK_BW_ITEM_NAME
# (default PLUNK_SECRET_KEY) in the shared deploy folder, or from the
# PLUNK_SECRET_KEY environment variable when set.
#
# Usage:
#   monitoring/install-alerting.zsh [host]              install/update
#   monitoring/install-alerting.zsh [host] --test       ...then fire a test alert
#   monitoring/install-alerting.zsh [host] --keep-secret  rerun without Bitwarden,
#                                                         keeping the secret already on the host

TARGET_HOST="${1:-${TARGET_HOST:-sky}}"
SEND_TEST_ALERT=0
KEEP_SECRET=0
for arg in "$@"; do
  [[ "$arg" == "--test" ]] && SEND_TEST_ALERT=1
  [[ "$arg" == "--keep-secret" ]] && KEEP_SECRET=1
done

REMOTE_DIR="${REMOTE_DIR:-\$HOME/monitoring}"
ALERTMANAGER_IMAGE="${ALERTMANAGER_IMAGE:-prom/alertmanager:latest}"
ALERTMANAGER_HOST_PORT="${ALERTMANAGER_HOST_PORT:-9093}"

ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-mike.wagstaff@gmail.com}"
ALERT_EMAIL_FROM="${ALERT_EMAIL_FROM:-alerts@skynolimit.dev}"
PLUNK_SMTP_HOST="${PLUNK_SMTP_HOST:-next-smtp.useplunk.com}"
PLUNK_SMTP_PORT="${PLUNK_SMTP_PORT:-2587}"   # STARTTLS submission port
PLUNK_SMTP_USERNAME="${PLUNK_SMTP_USERNAME:-plunk}"
PLUNK_BW_ITEM_NAME="${PLUNK_BW_ITEM_NAME:-PLUNK_SECRET_KEY}"
ALERT_REPEAT_INTERVAL="${ALERT_REPEAT_INTERVAL:-4h}"

BW_FOLDER_ID="${BW_FOLDER_ID:-7a5cbc24-a5c4-4d07-bbf3-b3f600e24660}"
BW_SESSION_CACHE_ENABLED="${BW_SESSION_CACHE_ENABLED:-1}"
BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"

have_valid_bw_session() {
  [[ -n "${BW_SESSION:-}" ]] || return 1
  bw --nointeraction --session "$BW_SESSION" list items --folderid "$BW_FOLDER_ID" >/dev/null 2>&1
}

cache_bw_session() {
  [[ "$BW_SESSION_CACHE_ENABLED" == "1" ]] || return 0
  [[ -n "${BW_SESSION:-}" ]] || return 0
  mkdir -p "${BW_SESSION_CACHE_FILE:h}"
  umask 077
  printf '%s\n' "$BW_SESSION" > "$BW_SESSION_CACHE_FILE"
  chmod 600 "$BW_SESSION_CACHE_FILE"
}

load_cached_bw_session() {
  [[ "$BW_SESSION_CACHE_ENABLED" == "1" ]] || return 1
  [[ -f "$BW_SESSION_CACHE_FILE" ]] || return 1
  BW_SESSION="$(<"$BW_SESSION_CACHE_FILE")"
  export BW_SESSION
  [[ -n "$BW_SESSION" ]] && have_valid_bw_session && {
    echo "==> Using cached Bitwarden session from ${BW_SESSION_CACHE_FILE}"
    return 0
  }
  rm -f "$BW_SESSION_CACHE_FILE"
  unset BW_SESSION
  return 1
}

ensure_bw_session() {
  for tool in bw jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: '$tool' is required but was not found in PATH" >&2; exit 1; }
  done
  have_valid_bw_session && return
  load_cached_bw_session && return
  bw login --check >/dev/null 2>&1 || { echo "==> Bitwarden login required..."; bw login; }
  echo "==> Unlocking Bitwarden vault..."
  BW_SESSION="$(bw unlock --raw)"
  export BW_SESSION
  have_valid_bw_session || { echo "Error: Could not establish a valid Bitwarden session" >&2; exit 1; }
  cache_bw_session
}

load_plunk_secret() {
  if [[ "$KEEP_SECRET" == "1" ]]; then
    PLUNK_SECRET_KEY=""
    PLUNK_SECRET_SOURCE="existing file on host (--keep-secret)"
    return
  fi
  if [[ -n "${PLUNK_SECRET_KEY:-}" ]]; then
    PLUNK_SECRET_SOURCE="environment"
    return
  fi
  ensure_bw_session
  echo "==> Refreshing Bitwarden vault data..."
  bw --nointeraction --session "$BW_SESSION" sync >/dev/null
  # Same value resolution as deploy/node_project.zsh: first custom field that
  # is not "Apps", falling back to the login password.
  PLUNK_SECRET_KEY="$(
    bw --nointeraction --session "$BW_SESSION" list items --folderid "$BW_FOLDER_ID" --search "$PLUNK_BW_ITEM_NAME" 2>/dev/null \
      | jq -r --arg name "$PLUNK_BW_ITEM_NAME" '
          .[] | select(.name == $name)
          | (([.fields[]? | select((.name // "" | ascii_downcase) != "apps") | .value | select(. != null and . != "")][0])
             // (.login.password // ""))' \
      | head -n 1
  )"
  if [[ -z "$PLUNK_SECRET_KEY" ]]; then
    echo "Error: Bitwarden item '$PLUNK_BW_ITEM_NAME' was not found in folder $BW_FOLDER_ID or has no value" >&2
    exit 1
  fi
  PLUNK_SECRET_SOURCE="Bitwarden item '$PLUNK_BW_ITEM_NAME'"
}

load_plunk_secret
PLUNK_SECRET_KEY_B64="$(printf '%s' "$PLUNK_SECRET_KEY" | base64 | tr -d '\n')"

echo "==> Installing Alertmanager on: ${TARGET_HOST}"
echo "==> Remote dir: ${REMOTE_DIR}"
echo "==> Alertmanager port: ${ALERTMANAGER_HOST_PORT} -> container 9093"
echo "==> Email: ${ALERT_EMAIL_FROM} -> ${ALERT_EMAIL_TO} via ${PLUNK_SMTP_HOST}:${PLUNK_SMTP_PORT}"
echo "==> Plunk secret source: ${PLUNK_SECRET_SOURCE}"
echo "==> Repeat interval for unresolved alerts: ${ALERT_REPEAT_INTERVAL}"
echo

ssh -o BatchMode=yes "${TARGET_HOST}" "bash -s" <<EOF
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR}"
case "\$REMOTE_DIR" in
  "~") REMOTE_DIR="\$HOME" ;;
  "~/"*) REMOTE_DIR="\$HOME/\${REMOTE_DIR#\~/}" ;;
esac
cd "\$REMOTE_DIR"
[[ -f docker-compose.yml && -f prometheus.yml ]] || { echo "Error: \$REMOTE_DIR is not a monitoring stack (run install-monitoring.zsh first)" >&2; exit 1; }

mkdir -p rules secrets
# The alertmanager image runs as nobody (uid 65534); only that uid and root can
# read the secret. The directory is traversable but not listable by others.
chmod 711 secrets
if [[ -n "${PLUNK_SECRET_KEY_B64}" ]]; then
  rm -f secrets/plunk-smtp-password
  umask 077
  printf '%s' "${PLUNK_SECRET_KEY_B64}" | base64 -d > secrets/plunk-smtp-password
  umask 022
elif [[ ! -f secrets/plunk-smtp-password ]]; then
  echo "Error: --keep-secret given but secrets/plunk-smtp-password does not exist on the host" >&2
  exit 1
fi
sudo chown 65534:65534 secrets/plunk-smtp-password
sudo chmod 400 secrets/plunk-smtp-password

# ---- alertmanager.yml -------------------------------------------------------
cat > alertmanager.yml <<'YAML'
# Managed by server-tooling/monitoring/install-alerting.zsh
global:
  smtp_smarthost: '${PLUNK_SMTP_HOST}:${PLUNK_SMTP_PORT}'
  smtp_from: '${ALERT_EMAIL_FROM}'
  smtp_auth_username: '${PLUNK_SMTP_USERNAME}'
  smtp_auth_password_file: /etc/alertmanager/secrets/plunk-smtp-password
  smtp_require_tls: true

route:
  receiver: email
  group_by: ['alertname', 'service_name', 'job']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: ${ALERT_REPEAT_INTERVAL}
  routes:
    # The always-firing Watchdog proves the pipeline is alive without emailing.
    - matchers: ['alertname = Watchdog']
      receiver: 'null'

receivers:
  - name: email
    email_configs:
      - to: '${ALERT_EMAIL_TO}'
        send_resolved: true
        headers:
          Subject: '[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}{{ if .CommonLabels.service_name }} — {{ .CommonLabels.service_name }}{{ else if .CommonLabels.job }} — {{ .CommonLabels.job }}{{ end }}'
  - name: 'null'

inhibit_rules:
  # A down target makes every other alert about it redundant.
  - source_matchers: ['alertname = TargetDown']
    target_matchers: ['alertname != TargetDown']
    equal: ['job']
  - source_matchers: ['severity = critical']
    target_matchers: ['severity = warning']
    equal: ['job', 'service_name']
YAML

# ---- rules/_generic.yml -----------------------------------------------------
cat > rules/_generic.yml <<'YAML'
# Managed by server-tooling/monitoring/install-alerting.zsh
# Alerts that apply to every job Prometheus scrapes. Per-project rules live in
# rules/<project>.yml and are installed by deploy/node_project.zsh.
groups:
  - name: generic
    rules:
      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
        annotations:
          summary: Always firing; proves Prometheus -> Alertmanager is alive

      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: '{{ \$labels.job }} is not answering /metrics'
          description: 'Prometheus has failed to scrape {{ \$labels.instance }} ({{ \$labels.job }}) for 3 minutes.'

      # Convention: any app can export app_check_ok{check="<name>"} as 1/0 and
      # gets an alert for free when a check stays unhealthy.
      - alert: AppCheckFailing
        expr: app_check_ok == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: '{{ \$labels.service_name }}{{ if not \$labels.service_name }}{{ \$labels.job }}{{ end }}: check "{{ \$labels.check }}" failing'
          description: 'app_check_ok{check="{{ \$labels.check }}"} has been 0 for 5 minutes on {{ \$labels.instance }}.'

      - alert: AppCheckFailingLong
        expr: app_check_ok == 0
        for: 30m
        labels:
          severity: critical
        annotations:
          summary: '{{ \$labels.service_name }}{{ if not \$labels.service_name }}{{ \$labels.job }}{{ end }}: check "{{ \$labels.check }}" failing for 30m'
YAML

# ---- docker-compose.yml: alertmanager service + rules mount -----------------
if ! grep -q 'rules:/etc/prometheus/rules' docker-compose.yml; then
  awk '
    { print }
    /^      - \.\/prometheus\.yml:\/etc\/prometheus\/prometheus\.yml:ro[[:space:]]*$/ && !done {
      print "      - ./rules:/etc/prometheus/rules:ro"
      done = 1
    }
  ' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
fi

BEGIN_MARK="  # BEGIN alertmanager managed service"
END_MARK="  # END alertmanager managed service"
BLOCK_FILE="\$(mktemp)"
cat > "\$BLOCK_FILE" <<'BLOCK'
  # BEGIN alertmanager managed service
  alertmanager:
    image: ${ALERTMANAGER_IMAGE}
    container_name: alertmanager
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - ./secrets:/etc/alertmanager/secrets:ro
      - alertmanager_data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
      - "--web.external-url=http://localhost:${ALERTMANAGER_HOST_PORT}"
    ports:
      - "127.0.0.1:${ALERTMANAGER_HOST_PORT}:9093"
    restart: unless-stopped
  # END alertmanager managed service
BLOCK
# Managed blocks are replaced in place; the block file avoids multi-line awk -v
# values, which BSD awk rejects.
awk -v begin="\$BEGIN_MARK" -v end="\$END_MARK" -v blockfile="\$BLOCK_FILE" '
  function emit(   line) { while ((getline line < blockfile) > 0) print line; close(blockfile) }
  BEGIN { skipping = 0; inserted = 0 }
  \$0 == begin { skipping = 1; next }
  skipping && \$0 == end { skipping = 0; next }
  skipping { next }
  # Insert before the first top-level key after services: (normally volumes:).
  /^services:[[:space:]]*\$/ { in_services = 1; print; next }
  in_services && !inserted && /^[^[:space:]#]/ { emit(); inserted = 1; in_services = 0 }
  { print }
  END { if (!inserted) emit() }
' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
rm -f "\$BLOCK_FILE"

if ! grep -qE '^  alertmanager_data:' docker-compose.yml; then
  if grep -qE '^volumes:[[:space:]]*\$' docker-compose.yml; then
    awk '{ print } /^volumes:[[:space:]]*\$/ && !done { print "  alertmanager_data:"; done = 1 }' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
  else
    printf '\nvolumes:\n  alertmanager_data:\n' >> docker-compose.yml
  fi
fi

# ---- prometheus.yml: alerting + rule_files ----------------------------------
PBEGIN="# BEGIN alertmanager managed alerting config"
PEND="# END alertmanager managed alerting config"
BLOCK_FILE="\$(mktemp)"
cat > "\$BLOCK_FILE" <<'BLOCK'
# BEGIN alertmanager managed alerting config
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
rule_files:
  - /etc/prometheus/rules/*.yml
# END alertmanager managed alerting config
BLOCK
# prometheus.yml is bind-mounted as a single file: write it in place (same
# inode) so the running container sees the change; never mv over it.
awk -v begin="\$PBEGIN" -v end="\$PEND" -v blockfile="\$BLOCK_FILE" '
  function emit(   line) { while ((getline line < blockfile) > 0) print line; close(blockfile) }
  BEGIN { skipping = 0; inserted = 0 }
  \$0 == begin { skipping = 1; next }
  skipping && \$0 == end { skipping = 0; next }
  skipping { next }
  !inserted && /^scrape_configs:[[:space:]]*\$/ { emit(); inserted = 1 }
  { print }
  END { if (!inserted) emit() }
' prometheus.yml > prometheus.yml.tmp && cat prometheus.yml.tmp > prometheus.yml && rm -f prometheus.yml.tmp "\$BLOCK_FILE"

# ---- Grafana: show Alertmanager alerts in the UI ----------------------------
mkdir -p grafana-provisioning/datasources
GRAFANA_DS_NEW=0
if [[ ! -f grafana-provisioning/datasources/alertmanager.yml ]]; then
  GRAFANA_DS_NEW=1
  cat > grafana-provisioning/datasources/alertmanager.yml <<'YAML'
# Managed by server-tooling/monitoring/install-alerting.zsh
apiVersion: 1
datasources:
  - name: Alertmanager
    uid: alertmanager
    type: alertmanager
    access: proxy
    url: http://alertmanager:9093
    jsonData:
      implementation: prometheus
      handleGrafanaManagedAlerts: false
YAML
fi

# ---- validate + apply -------------------------------------------------------
DOCKER="docker"
docker ps >/dev/null 2>&1 || DOCKER="sudo docker"
DC="\$DOCKER compose"

echo "==> Validating configuration"
\$DC -f docker-compose.yml config -q
\$DOCKER run --rm -v "\$REMOTE_DIR/alertmanager.yml:/cfg/alertmanager.yml:ro" -v "\$REMOTE_DIR/secrets:/etc/alertmanager/secrets:ro" --entrypoint amtool "${ALERTMANAGER_IMAGE}" check-config /cfg/alertmanager.yml
\$DOCKER run --rm -v "\$REMOTE_DIR/rules:/rules:ro" --entrypoint sh prom/prometheus:latest -c 'promtool check rules /rules/*.yml'
\$DOCKER run --rm -v "\$REMOTE_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "\$REMOTE_DIR/rules:/etc/prometheus/rules:ro" --entrypoint promtool prom/prometheus:latest check config /etc/prometheus/prometheus.yml

echo "==> Starting Alertmanager and applying Prometheus changes"
\$DC -f docker-compose.yml up -d alertmanager prometheus
# up -d only recreates containers whose definition changed; reload both so
# in-place config edits are picked up on reruns too.
curl -fsS -X POST "http://localhost:${ALERTMANAGER_HOST_PORT}/-/reload" >/dev/null 2>&1 || true
curl -fsS -X POST http://localhost:9090/-/reload >/dev/null 2>&1 || true
if [[ "\$GRAFANA_DS_NEW" == "1" ]]; then
  \$DC -f docker-compose.yml restart grafana >/dev/null
fi

for attempt in \$(seq 1 20); do
  if curl -fsS "http://localhost:${ALERTMANAGER_HOST_PORT}/-/ready" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "http://localhost:${ALERTMANAGER_HOST_PORT}/-/ready" >/dev/null || { echo "Error: Alertmanager did not become ready" >&2; \$DOCKER logs --tail 50 alertmanager >&2; exit 1; }
for attempt in \$(seq 1 20); do
  if curl -fsS http://localhost:9090/-/ready >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "==> Prometheus alertmanager discovery:"
curl -fsS http://localhost:9090/api/v1/alertmanagers | jq -r '.data.activeAlertmanagers[].url'
echo "==> Loaded rule groups:"
curl -fsS http://localhost:9090/api/v1/rules | jq -r '.data.groups[] | "   \(.file): \(.name) (\(.rules | length) rules)"'

if [[ "${SEND_TEST_ALERT}" == "1" ]]; then
  echo "==> Sending a test alert (resolves itself after 2 minutes)"
  ENDS_AT="\$(date -u -d '+2 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  curl -fsS -XPOST "http://localhost:${ALERTMANAGER_HOST_PORT}/api/v2/alerts" -H 'Content-Type: application/json' -d "[{
    \"labels\": {\"alertname\": \"TestAlert\", \"severity\": \"warning\", \"service_name\": \"install-alerting\"},
    \"annotations\": {\"summary\": \"Test alert from install-alerting.zsh\", \"description\": \"If you can read this, Prometheus Alertmanager -> Plunk -> your inbox works.\"},
    \"endsAt\": \"\$ENDS_AT\"
  }]"
  echo "   Sent; the email should arrive within ~1 minute (group_wait 30s). A resolved email follows a few minutes later."
fi

echo "==> Done. Alertmanager UI: ssh -L ${ALERTMANAGER_HOST_PORT}:localhost:${ALERTMANAGER_HOST_PORT} ${TARGET_HOST}  then http://localhost:${ALERTMANAGER_HOST_PORT}"
EOF
