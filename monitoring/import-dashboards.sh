#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="${DASHBOARD_DIR:-$SCRIPT_DIR/dashboards}"

GRAFANA_URL="${GRAFANA_URL:-https://api.skynolimit.dev/grafana}"
API="$GRAFANA_URL/api"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:?GRAFANA_PASSWORD must be set}"

sanitize_slug() {
  local raw="${1:-}"
  local slug
  slug="$(echo "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$slug" ]]; then
    slug="project"
  fi
  echo "$slug"
}

to_grafana_uid() {
  local raw="${1:-}"
  local uid
  uid="$(sanitize_slug "$raw")"
  # Grafana UID limit is 40 characters.
  echo "${uid:0:40}"
}

PROJECT_NAME="${PROJECT_NAME:-${APP_NAME:-project}}"
PROJECT_SLUG="$(sanitize_slug "${PROJECT_SLUG:-$PROJECT_NAME}")"

FOLDER_UID="$(to_grafana_uid "${FOLDER_UID:-${PROJECT_SLUG}-dashboards}")"
FOLDER_TITLE="${FOLDER_TITLE:-$PROJECT_NAME}"
PROM_DS_NAME="${PROM_DS_NAME:-${PROJECT_SLUG}-prometheus}"
PROM_DS_UID="$(to_grafana_uid "${PROM_DS_UID:-${PROJECT_SLUG}-prometheus}")"
# Datasource URL is resolved by Grafana (running in Docker), not by the host shell.
PROM_DS_URL="${PROM_DS_URL:-http://prometheus:9090}"

PROM_CONFIG_HOST="${PROM_CONFIG_HOST:-${DEPLOY_HOST:-}}"
PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-/etc/prometheus/prometheus.yml}"
PROM_RELOAD_URL="${PROM_RELOAD_URL:-http://localhost:9090/-/reload}"
PROM_SCRAPE_JOB_NAME="${PROM_SCRAPE_JOB_NAME:-$PROJECT_SLUG}"
PROM_SCRAPE_TARGET="${PROM_SCRAPE_TARGET:-host.docker.internal:${METRICS_PORT:-3010}}"
PROM_SCRAPE_METRICS_PATH="${PROM_SCRAPE_METRICS_PATH:-/metrics}"

curl_json() {
  curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -H "Content-Type: application/json" "$@"
}

url_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

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

ensure_prometheus_datasource() {
  local ds_url response existing_id existing_type
  local existing_uid existing_name existing_url create_payload created_id update_payload

  ds_url="$PROM_DS_URL"

  # Prefer lookup by UID to avoid colliding with generic names like "Prometheus".
  response="$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$API/datasources/uid/$(url_encode "$PROM_DS_UID")")"
  existing_id="$(jq -r '.id // empty' <<< "$response")"

  if [[ -z "$existing_id" ]]; then
    response="$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
      "$API/datasources/name/$(url_encode "$PROM_DS_NAME")")"
    existing_id="$(jq -r '.id // empty' <<< "$response")"
  fi

  existing_type="$(jq -r '.type // empty' <<< "$response")"
  existing_uid="$(jq -r '.uid // empty' <<< "$response")"
  existing_name="$(jq -r '.name // empty' <<< "$response")"
  existing_url="$(jq -r '.url // empty' <<< "$response")"

  if [[ -n "$existing_id" ]]; then
    if [[ "$existing_type" != "prometheus" ]]; then
      echo "Existing data source \"$existing_name\" is type \"$existing_type\", expected \"prometheus\"." >&2
      exit 1
    fi

    # Align import behavior with the datasource that actually exists.
    if [[ -n "$existing_uid" ]]; then
      PROM_DS_UID="$existing_uid"
    fi
    if [[ "$existing_url" == "$ds_url" && "$existing_name" == "$PROM_DS_NAME" ]]; then
      echo "Using existing Prometheus data source \"$PROM_DS_NAME\" (uid=$PROM_DS_UID, url=$existing_url)"
      return
    fi

    update_payload="$(
      jq -cn \
        --arg name "$PROM_DS_NAME" \
        --arg uid "$PROM_DS_UID" \
        --arg url "$ds_url" \
        '{
          name: $name,
          uid: $uid,
          type: "prometheus",
          access: "proxy",
          url: $url,
          basicAuth: false,
          jsonData: {httpMethod: "POST"}
        }'
    )"

    response="$(curl_json -X PUT "$API/datasources/uid/$(url_encode "$PROM_DS_UID")" -d "$update_payload")"
    if [[ "$(jq -r '.message // empty' <<< "$response")" != "Datasource updated" ]]; then
      echo "Failed to update Prometheus data source \"$PROM_DS_NAME\": $(jq -r '.message // "unknown error"' <<< "$response")" >&2
      exit 1
    fi

    echo "Updated Prometheus data source \"$PROM_DS_NAME\" -> $ds_url (uid=$PROM_DS_UID)"
    return
  fi

  create_payload="$(
    jq -cn \
      --arg name "$PROM_DS_NAME" \
      --arg uid "$PROM_DS_UID" \
      --arg url "$ds_url" \
      '{
        name: $name,
        uid: $uid,
        type: "prometheus",
        access: "proxy",
        url: $url,
        basicAuth: false,
        jsonData: {httpMethod: "POST"}
      }'
  )"

  response="$(curl_json -X POST "$API/datasources" -d "$create_payload")"
  created_id="$(jq -r '.datasource.id // .id // empty' <<< "$response")"
  if [[ -z "$created_id" ]]; then
    echo "Failed to create Prometheus data source \"$PROM_DS_NAME\": $(jq -r '.message // "unknown error"' <<< "$response")" >&2
    exit 1
  fi

  if [[ -n "$(jq -r '.datasource.uid // empty' <<< "$response")" ]]; then
    PROM_DS_UID="$(jq -r '.datasource.uid' <<< "$response")"
  fi

  echo "Created Prometheus data source \"$PROM_DS_NAME\" -> $ds_url (id=$created_id, uid=$PROM_DS_UID)"
}

upsert_prometheus_scrape_config_file() {
  local config_file="$1"
  local begin_marker end_marker block tmp_file

  begin_marker="# BEGIN ${PROM_SCRAPE_JOB_NAME} managed scrape config"
  end_marker="# END ${PROM_SCRAPE_JOB_NAME} managed scrape config"

  block="$(cat <<EOF
${begin_marker}
  - job_name: '${PROM_SCRAPE_JOB_NAME}'
    metrics_path: '${PROM_SCRAPE_METRICS_PATH}'
    static_configs:
      - targets: ['${PROM_SCRAPE_TARGET}']
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
    echo "Prometheus reload endpoint returned 403 (likely --web.enable-lifecycle not enabled); restarting container instead..."
    if restart_prometheus_container; then
      echo "Restarted Prometheus container to apply config"
      return
    fi
  fi

  echo "Warning: failed to reload Prometheus via $reload_url. Restart Prometheus manually if needed." >&2
}

ensure_prometheus_scrape_config() {
  if [[ -n "$PROM_CONFIG_HOST" ]]; then
    echo "Upserting Prometheus scrape config on host $PROM_CONFIG_HOST ..."
    ssh "$PROM_CONFIG_HOST" bash -s -- \
      "$PROM_CONFIG_FILE" \
      "$PROM_SCRAPE_JOB_NAME" \
      "$PROM_SCRAPE_METRICS_PATH" \
      "$PROM_SCRAPE_TARGET" \
      "$PROM_RELOAD_URL" <<'EOF'
set -euo pipefail

config_file="$1"
job_name="$2"
metrics_path="$3"
target="$4"
reload_url="$5"

if [[ "$config_file" == "~" ]]; then
  config_file="$HOME"
elif [[ "$config_file" == "~/"* ]]; then
  config_file="$HOME/${config_file#~/}"
fi

mounted_config_file="$(
  sudo docker inspect prometheus --format '{{range .Mounts}}{{if eq .Destination "/etc/prometheus/prometheus.yml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true
)"
if [[ -n "$mounted_config_file" ]]; then
  config_file="$mounted_config_file"
fi

begin_marker="# BEGIN ${job_name} managed scrape config"
end_marker="# END ${job_name} managed scrape config"

block="$(cat <<BLOCK
${begin_marker}
  - job_name: '${job_name}'
    metrics_path: '${metrics_path}'
    static_configs:
      - targets: ['${target}']
${end_marker}
BLOCK
)"

if [[ ! -f "$config_file" ]]; then
  mkdir -p "$(dirname "$config_file")"
  cat > "$config_file" <<'CFG'
global:
  scrape_interval: 15s
scrape_configs:
CFG
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

echo "Upserted Prometheus scrape job \"$job_name\" in $config_file"

http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$reload_url" || true)"
if [[ "$http_code" == "200" ]]; then
  echo "Reloaded Prometheus config via $reload_url"
elif [[ "$http_code" == "403" ]]; then
  monitoring_dir="$(dirname "$config_file")"
  compose_file="$monitoring_dir/docker-compose.yml"
  echo "Prometheus reload endpoint returned 403 (likely --web.enable-lifecycle not enabled); restarting container instead..."
  if [[ -f "$compose_file" ]]; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      if docker compose -f "$compose_file" restart prometheus >/dev/null 2>&1; then
        echo "Restarted Prometheus container to apply config"
        exit 0
      fi
      if command -v sudo >/dev/null 2>&1 && sudo docker compose -f "$compose_file" restart prometheus >/dev/null 2>&1; then
        echo "Restarted Prometheus container to apply config"
        exit 0
      fi
    fi
    if command -v docker-compose >/dev/null 2>&1; then
      if docker-compose -f "$compose_file" restart prometheus >/dev/null 2>&1; then
        echo "Restarted Prometheus container to apply config"
        exit 0
      fi
      if command -v sudo >/dev/null 2>&1 && sudo docker-compose -f "$compose_file" restart prometheus >/dev/null 2>&1; then
        echo "Restarted Prometheus container to apply config"
        exit 0
      fi
    fi
  fi
  echo "Warning: reload was forbidden and automatic restart failed. Restart Prometheus manually if needed." >&2
else
  echo "Warning: failed to reload Prometheus via $reload_url. Restart Prometheus manually if needed." >&2
fi
EOF
    return
  fi

  PROM_CONFIG_FILE="$(expand_tilde_path "$PROM_CONFIG_FILE")"
  upsert_prometheus_scrape_config_file "$PROM_CONFIG_FILE"
  reload_prometheus "$PROM_RELOAD_URL" "$PROM_CONFIG_FILE"
}

ensure_folder() {
  local existing_uid query response created_uid

  # Prefer explicit folder UID if it already exists.
  existing_uid="$(
    curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$API/folders/$FOLDER_UID" \
      | jq -r '.uid // empty'
  )"
  if [[ "$existing_uid" == "$FOLDER_UID" ]]; then
    echo "Using existing folder uid=$FOLDER_UID"
    return
  fi

  # Fall back to an existing folder title if present.
  query="$(url_encode "$FOLDER_TITLE")"
  existing_uid="$(
    curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$API/search?type=dash-folder&query=$query" \
      | jq -r --arg t "$FOLDER_TITLE" '.[] | select(.title == $t) | .uid' \
      | head -n 1
  )"

  if [[ -n "$existing_uid" ]]; then
    FOLDER_UID="$existing_uid"
    echo "Using existing folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
    return
  fi

  response="$(
    jq -cn --arg uid "$FOLDER_UID" --arg title "$FOLDER_TITLE" '{uid: $uid, title: $title}' \
      | curl_json -X POST "$API/folders" -d @-
  )"

  created_uid="$(jq -r '.uid // empty' <<< "$response")"
  if [[ -z "$created_uid" ]]; then
    echo "Failed to create Grafana folder \"$FOLDER_TITLE\": $(jq -r '.message // "unknown error"' <<< "$response")" >&2
    exit 1
  fi

  FOLDER_UID="$created_uid"
  echo "Created folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
}

delete_dashboard_uid() {
  local uid="$1"
  local reason="${2:-dashboard}"
  echo "Deleting $reason uid=$uid"
  curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -X DELETE "$API/dashboards/uid/$uid" >/dev/null
}

dashboard_uid_for_file() {
  local file="$1"
  local filename uid

  filename="$(basename "$file")"
  uid="$(jq -r '.uid // empty' "$file")"

  # If UID is missing, derive one from the filename (stable across imports)
  if [[ -z "$uid" ]]; then
    uid="${filename%.json}"
    uid="${uid//[^a-zA-Z0-9_-]/-}"
    uid="$(echo "$uid" | tr '[:upper:]' '[:lower:]')"
  fi

  echo "$uid"
}

inject_datasource_in_dashboard() {
  local file="$1"
  local temp_file

  temp_file="$(mktemp)"
  jq \
    --arg ds_uid "$PROM_DS_UID" \
    '
      def normalize_prom_ds:
        if type == "object" then
          (if has("targets") then
             . + {
               datasource:
                 (if ((has("datasource") | not)
                      or .datasource == null
                      or .datasource == ""
                      or ((.datasource | type) == "string")
                      or (((.datasource | type) == "object") and ((.datasource.uid // "") == "")))
                  then {type: "prometheus", uid: $ds_uid}
                  else .datasource
                  end),
               datasourceUid:
                 (if ((has("datasourceUid") | not)
                      or .datasourceUid == null
                      or .datasourceUid == ""
                      or ((.datasourceUid | type) == "string"))
                  then $ds_uid
                  else .datasourceUid
                  end)
             }
           else
             .
           end)
          | with_entries(.value |= normalize_prom_ds)
        elif type == "array" then
          map(normalize_prom_ds)
        else
          .
        end;
      normalize_prom_ds
    ' \
    "$file" > "$temp_file"

  mv "$temp_file" "$file"
}

import_dashboard_file() {
  local file="$1"
  local uid title payload encoded_title normalized_file

  normalized_file="$(mktemp)"
  cp "$file" "$normalized_file"
  inject_datasource_in_dashboard "$normalized_file"

  # Derive UID from the original dashboard file path (not the temporary copy).
  uid="$(dashboard_uid_for_file "$file")"
  title="$(jq -r '.title' "$normalized_file")"

  echo "Importing: $title (uid=$uid) from $file"

  # Find existing dashboards with the same title (likely dupes)
  # and delete any that aren't the UID we're about to use.
  # (We scope by folderUid to avoid nuking similarly-named dashboards elsewhere.)
  encoded_title="$(url_encode "$title")"
  existing_uids="$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$API/search?type=dash-db&folderUids=$FOLDER_UID&query=$encoded_title" \
    | jq -r --arg t "$title" '.[] | select(.title == $t) | .uid')"

  if [[ -n "${existing_uids:-}" ]]; then
    while IFS= read -r existing_uid; do
      [[ -z "$existing_uid" ]] && continue
      if [[ "$existing_uid" != "$uid" ]]; then
        delete_dashboard_uid "$existing_uid" "duplicate dashboard"
      fi
    done <<< "$existing_uids"
  fi

  # Build the import payload.
  # Ensure stable uid, and id=null so Grafana doesn't try to tie to a stale numeric id.
  payload="$(jq -c --arg folder "$FOLDER_UID" --arg uid "$uid" '
    {
      dashboard: (. + {uid: $uid, id: null}),
      folderUid: $folder,
      overwrite: true
    }' "$normalized_file")"

  rm -f "$normalized_file"

  curl_json -X POST "$API/dashboards/db" -d "$payload" | jq -r '.status // .message'
}

delete_dashboards_missing_locally() {
  local local_uids uid file dashboard_data folder_uid

  # Safety check: ensure FOLDER_UID is set before deleting anything
  if [[ -z "$FOLDER_UID" ]]; then
    echo "Warning: FOLDER_UID not set, skipping stale dashboard deletion" >&2
    return
  fi

  local_uids=""
  for file in "$DASHBOARD_DIR"/*.json; do
    [[ -f "$file" ]] || continue
    uid="$(dashboard_uid_for_file "$file")"
    local_uids+="$uid"$'\n'
  done

  echo "Checking for stale dashboards in folder uid=$FOLDER_UID"

  # Get ALL dashboards, then filter by folderUid in jq (more reliable than API parameter)
  curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$API/search?type=dash-db" | \
    jq -r --arg folder_uid "$FOLDER_UID" \
      '.[] | select(.folderUid == $folder_uid) | .uid' | \
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue

    # Double-check the dashboard actually belongs to our folder by fetching its metadata
    dashboard_data="$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$API/dashboards/uid/$uid")"
    folder_uid="$(echo "$dashboard_data" | jq -r '.meta.folderUid // empty')"

    # Only delete if it's truly in our folder AND not in our local files
    if [[ "$folder_uid" == "$FOLDER_UID" ]]; then
      if ! grep -Fxq "$uid" <<< "$local_uids"; then
        echo "Found stale dashboard in our folder: $uid"
        delete_dashboard_uid "$uid" "stale dashboard"
      fi
    else
      echo "Warning: Dashboard $uid not in our folder (folderUid=$folder_uid), skipping"
    fi
  done

  echo "Stale dashboard check complete"
}

if [[ ! -d "$DASHBOARD_DIR" ]]; then
  echo "Dashboard directory not found: $DASHBOARD_DIR" >&2
  echo "Set DASHBOARD_DIR to the folder containing dashboard JSON files." >&2
  exit 1
fi

shopt -s nullglob
files=("$DASHBOARD_DIR"/*.json)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No dashboards found in: $DASHBOARD_DIR"
  exit 1
fi

ensure_folder
ensure_prometheus_scrape_config
ensure_prometheus_datasource

for f in "${files[@]}"; do
  import_dashboard_file "$f"
done

delete_dashboards_missing_locally

echo "Done."
