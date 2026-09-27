#!/usr/bin/env bash
set -euo pipefail

# Installs a project's Prometheus alert rules on the monitoring host as
# rules/<job>.yml next to prometheus.yml, validates them with promtool and
# reloads Prometheus. Called by deploy/node_project.zsh after the scrape
# target is configured; requires monitoring/install-alerting.zsh to have run
# once (it adds rule_files to prometheus.yml), otherwise the rules are skipped
# with a warning so a deploy is never blocked by missing alerting.
#
# Environment:
#   PROM_CONFIG_HOST      ssh host (default: DEPLOY_HOST)
#   PROM_RULES_FILE       local rules file (default: observability/prometheus/rules.yml)
#   PROM_RULES_JOB_NAME   remote file name stem, normally the scrape job name
#   PROM_CONFIG_FILE      remote prometheus.yml (default: ~/monitoring/prometheus.yml)
#   PROM_RELOAD_URL       default http://localhost:9090/-/reload
#   PROM_SKIP_RELOAD=1    write the file without reloading

PROM_CONFIG_HOST="${PROM_CONFIG_HOST:-${DEPLOY_HOST:-}}"
PROM_RULES_FILE="${PROM_RULES_FILE:-observability/prometheus/rules.yml}"
PROM_RULES_JOB_NAME="${PROM_RULES_JOB_NAME:-${PROM_SCRAPE_JOB_NAME:-${PROJECT_SLUG:-${PROJECT_NAME:-}}}}"
PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-~/monitoring/prometheus.yml}"
PROM_RELOAD_URL="${PROM_RELOAD_URL:-http://localhost:9090/-/reload}"
PROM_SKIP_RELOAD="${PROM_SKIP_RELOAD:-0}"

if [[ -z "$PROM_CONFIG_HOST" ]]; then
  echo "Error: PROM_CONFIG_HOST must be set" >&2
  exit 1
fi
if [[ -z "$PROM_RULES_JOB_NAME" || ! "$PROM_RULES_JOB_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Error: PROM_RULES_JOB_NAME must be a simple slug (got '${PROM_RULES_JOB_NAME}')" >&2
  exit 1
fi
if [[ ! -f "$PROM_RULES_FILE" ]]; then
  echo "Error: rules file not found: $PROM_RULES_FILE" >&2
  exit 1
fi

RULES_B64="$(base64 < "$PROM_RULES_FILE" | tr -d '\n')"

ssh -o BatchMode=yes "$PROM_CONFIG_HOST" "bash -s" <<EOF
set -euo pipefail

CONFIG_FILE="${PROM_CONFIG_FILE}"
case "\$CONFIG_FILE" in
  "~/"*) CONFIG_FILE="\$HOME/\${CONFIG_FILE#\~/}" ;;
esac
MONITORING_DIR="\$(dirname "\$CONFIG_FILE")"
RULES_DIR="\$MONITORING_DIR/rules"
TARGET="\$RULES_DIR/${PROM_RULES_JOB_NAME}.yml"

if [[ ! -f "\$CONFIG_FILE" ]] || ! grep -q '^rule_files:' "\$CONFIG_FILE"; then
  echo "Warning: Prometheus at \$CONFIG_FILE has no rule_files entry; run monitoring/install-alerting.zsh first. Skipping alert rules." >&2
  exit 0
fi
mkdir -p "\$RULES_DIR"

DOCKER="docker"
docker ps >/dev/null 2>&1 || DOCKER="sudo docker"

CANDIDATE="\$(mktemp "\$RULES_DIR/.${PROM_RULES_JOB_NAME}.XXXXXX")"
trap 'rm -f "\$CANDIDATE"' EXIT
printf '%s' "${RULES_B64}" | base64 -d > "\$CANDIDATE"
{
  echo "# Managed by deploy/node_project.zsh for project ${PROM_RULES_JOB_NAME}"
  echo "# Source: ${PROM_RULES_FILE}  Updated: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat "\$CANDIDATE"
} > "\$CANDIDATE.full" && mv "\$CANDIDATE.full" "\$CANDIDATE"

if ! \$DOCKER run --rm -v "\$CANDIDATE:/check/rules.yml:ro" --entrypoint promtool prom/prometheus:latest check rules /check/rules.yml; then
  echo "Error: ${PROM_RULES_FILE} failed promtool validation; existing rules left unchanged." >&2
  exit 1
fi

cat "\$CANDIDATE" > "\$TARGET"
chmod 644 "\$TARGET"
echo "Installed Prometheus alert rules for ${PROM_RULES_JOB_NAME} at \$TARGET"

if [[ "${PROM_SKIP_RELOAD}" == "1" ]]; then
  echo "Skipped Prometheus reload (PROM_SKIP_RELOAD=1)"
  exit 0
fi
http_code="\$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${PROM_RELOAD_URL}" || true)"
if [[ "\$http_code" == "200" ]]; then
  echo "Reloaded Prometheus config via ${PROM_RELOAD_URL}"
else
  echo "Prometheus reload returned HTTP \$http_code; restarting container instead..."
  \$DOCKER compose -f "\$MONITORING_DIR/docker-compose.yml" restart prometheus >/dev/null
fi
# Prometheus reports the container path, so match on the file name only.
loaded="\$(curl -fsS http://localhost:9090/api/v1/rules 2>/dev/null | jq -r --arg f "/${PROM_RULES_JOB_NAME}.yml" '[.data.groups[] | select(.file | endswith(\$f)) | .rules | length] | add // 0' || echo '?')"
echo "Prometheus now reports \$loaded rule(s) from ${PROM_RULES_JOB_NAME}.yml"
EOF
