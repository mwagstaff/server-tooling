#!/usr/bin/env bash
set -euo pipefail

PROM_CONFIG_HOST="${PROM_CONFIG_HOST:-${DEPLOY_HOST:-}}"
PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-/etc/prometheus/prometheus.yml}"
PROM_RELOAD_URL="${PROM_RELOAD_URL:-http://localhost:9090/-/reload}"
PROM_SCRAPE_JOB_NAME="${PROM_SCRAPE_JOB_NAME:-${PROJECT_SLUG:-${PROJECT_NAME:-project}}}"
PROM_SCRAPE_TARGETS="${PROM_SCRAPE_TARGETS:-${PROM_SCRAPE_TARGET:-}}"
PROM_SCRAPE_METRICS_PATH="${PROM_SCRAPE_METRICS_PATH:-/metrics}"
PROM_SKIP_RELOAD="${PROM_SKIP_RELOAD:-0}"
PROM_DISCOVER_DOCKER_CONFIG="${PROM_DISCOVER_DOCKER_CONFIG:-1}"

if [[ "${1:-}" == "--local" ]]; then
  PROM_CONFIG_HOST=""
  PROM_CONFIG_FILE="$2"
  PROM_SCRAPE_JOB_NAME="$3"
  PROM_SCRAPE_METRICS_PATH="$4"
  PROM_SCRAPE_TARGETS="$5"
  PROM_RELOAD_URL="$6"
  PROM_SKIP_RELOAD="$7"
  PROM_DISCOVER_DOCKER_CONFIG="$8"
fi

if [[ -z "$PROM_SCRAPE_JOB_NAME" ]]; then
  echo "Error: PROM_SCRAPE_JOB_NAME must not be empty" >&2
  exit 1
fi

if [[ -z "$PROM_SCRAPE_TARGETS" ]]; then
  echo "Error: PROM_SCRAPE_TARGETS must contain at least one target" >&2
  exit 1
fi

expand_tilde_path() {
  local path="$1"
  local home_dir="${2:-$HOME}"
  if [[ "$path" == "~" ]]; then
    echo "$home_dir"
    return
  fi
  if [[ "$path" == "~/"* ]]; then
    echo "$home_dir/${path#~/}"
    return
  fi
  echo "$path"
}

discover_prometheus_config_file() {
  local mounted_config_file

  [[ "$PROM_DISCOVER_DOCKER_CONFIG" == "1" ]] || return
  command -v docker >/dev/null 2>&1 || return

  mounted_config_file="$(
    sudo docker inspect prometheus \
      --format '{{range .Mounts}}{{if eq .Destination "/etc/prometheus/prometheus.yml"}}{{.Source}}{{end}}{{end}}' \
      2>/dev/null || true
  )"
  if [[ -n "$mounted_config_file" ]]; then
    PROM_CONFIG_FILE="$mounted_config_file"
  fi
}

upsert_prometheus_scrape_config_file() {
  local config_file="$1"
  local begin_marker end_marker block tmp_file target_yaml target
  local -a targets

  IFS=',' read -r -a targets <<< "$PROM_SCRAPE_TARGETS"
  target_yaml=""
  for target in "${targets[@]}"; do
    target="$(printf '%s' "$target" | xargs)"
    [[ -n "$target" ]] || continue
    target_yaml="${target_yaml}        - '${target}'"$'\n'
  done
  if [[ -z "$target_yaml" ]]; then
    echo "Error: no Prometheus scrape targets configured" >&2
    exit 1
  fi

  begin_marker="# BEGIN ${PROM_SCRAPE_JOB_NAME} managed scrape config"
  end_marker="# END ${PROM_SCRAPE_JOB_NAME} managed scrape config"

  block="$(cat <<EOF
${begin_marker}
  - job_name: '${PROM_SCRAPE_JOB_NAME}'
    metrics_path: '${PROM_SCRAPE_METRICS_PATH}'
    static_configs:
      - targets:
${target_yaml%$'\n'}
${end_marker}
EOF
)"

  mkdir -p "$(dirname "$config_file")"
  if [[ ! -f "$config_file" ]]; then
    cat > "$config_file" <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
EOF
  fi

  tmp_file="$(mktemp)"
  awk -v begin="$begin_marker" -v end="$end_marker" -v block="$block" '
    BEGIN {
      in_block = 0
      saw_scrape = 0
      inserted = 0
    }
    {
      if ($0 == begin) {
        in_block = 1
        next
      }
      if (in_block && $0 == end) {
        in_block = 0
        next
      }
      if (in_block) {
        next
      }

      if ($0 ~ /^scrape_configs:[[:space:]]*$/) {
        saw_scrape = 1
        print
        next
      }

      if (saw_scrape && !inserted && $0 ~ /^[^[:space:]#][^:]*:[[:space:]]*$/) {
        print block
        inserted = 1
        saw_scrape = 0
      }

      print
    }
    END {
      if (saw_scrape && !inserted) {
        print block
        inserted = 1
      }
      if (!inserted) {
        print ""
        print "scrape_configs:"
        print block
      }
    }
  ' "$config_file" > "$tmp_file"

  cat "$tmp_file" > "$config_file"
  rm -f "$tmp_file"

  echo "Upserted Prometheus scrape job \"$PROM_SCRAPE_JOB_NAME\" in $config_file"
}

reload_prometheus() {
  local reload_url="$1"
  local config_file="$2"
  local monitoring_dir compose_file http_code

  if [[ "$PROM_SKIP_RELOAD" == "1" ]]; then
    echo "Skipped Prometheus reload (PROM_SKIP_RELOAD=1)"
    return
  fi

  monitoring_dir="$(dirname "$config_file")"
  compose_file="$monitoring_dir/docker-compose.yml"

  restart_prometheus_container() {
    if [[ ! -f "$compose_file" ]]; then
      return 1
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      docker compose -f "$compose_file" restart prometheus >/dev/null 2>&1 && return 0
    fi
    if command -v docker-compose >/dev/null 2>&1; then
      docker-compose -f "$compose_file" restart prometheus >/dev/null 2>&1 && return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
      if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        sudo docker compose -f "$compose_file" restart prometheus >/dev/null 2>&1 && return 0
      fi
      if command -v docker-compose >/dev/null 2>&1; then
        sudo docker-compose -f "$compose_file" restart prometheus >/dev/null 2>&1 && return 0
      fi
    fi

    return 1
  }

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$reload_url" || true)"
  if [[ "$http_code" == "200" ]]; then
    echo "Reloaded Prometheus config via $reload_url"
    return
  fi

  if [[ "$http_code" == "403" ]]; then
    echo "Prometheus reload endpoint returned 403; restarting container instead..."
    if restart_prometheus_container; then
      echo "Restarted Prometheus container to apply config"
      return
    fi
  fi

  echo "Warning: failed to reload Prometheus via $reload_url. Restart Prometheus manually if needed." >&2
}

if [[ -n "$PROM_CONFIG_HOST" ]]; then
  ssh "$PROM_CONFIG_HOST" bash -s -- \
    --local \
    "$PROM_CONFIG_FILE" \
    "$PROM_SCRAPE_JOB_NAME" \
    "$PROM_SCRAPE_METRICS_PATH" \
    "$PROM_SCRAPE_TARGETS" \
    "$PROM_RELOAD_URL" \
    "$PROM_SKIP_RELOAD" \
    "$PROM_DISCOVER_DOCKER_CONFIG" < "$0"
  exit
fi

PROM_CONFIG_FILE="$(expand_tilde_path "$PROM_CONFIG_FILE")"
discover_prometheus_config_file
upsert_prometheus_scrape_config_file "$PROM_CONFIG_FILE"
reload_prometheus "$PROM_RELOAD_URL" "$PROM_CONFIG_FILE"
