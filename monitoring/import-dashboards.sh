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
PROM_SCRAPE_TARGETS="${PROM_SCRAPE_TARGETS:-$PROM_SCRAPE_TARGET}"
PROM_SCRAPE_METRICS_PATH="${PROM_SCRAPE_METRICS_PATH:-/metrics}"
GRAFANA_HOST_HEADER="${GRAFANA_HOST_HEADER:-}"
GRAFANA_FORWARDED_PROTO="${GRAFANA_FORWARDED_PROTO:-https}"
GRAFANA_FORWARDED_PREFIX="${GRAFANA_FORWARDED_PREFIX:-}"

grafana_curl() {
  local args
  args=(-sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD")
  if [[ -n "$GRAFANA_HOST_HEADER" ]]; then
    args+=(
      -H "Host: $GRAFANA_HOST_HEADER"
      -H "X-Forwarded-Host: $GRAFANA_HOST_HEADER"
      -H "X-Forwarded-Proto: $GRAFANA_FORWARDED_PROTO"
    )
  fi
  if [[ -n "$GRAFANA_FORWARDED_PREFIX" ]]; then
    args+=(-H "X-Forwarded-Prefix: $GRAFANA_FORWARDED_PREFIX")
  fi
  curl "${args[@]}" "$@"
}

curl_json() {
  grafana_curl -H "Content-Type: application/json" "$@"
}

curl_json_with_status() {
  local body_file status
  body_file="$(mktemp)"
  status="$(
    grafana_curl -H "Content-Type: application/json" \
      -o "$body_file" -w '%{http_code}' "$@"
  )"
  printf '%s\n' "$status"
  cat "$body_file"
  rm -f "$body_file"
}

grafana_error_message() {
  local response="$1"
  local message
  if jq -e . >/dev/null 2>&1 <<< "$response"; then
    message="$(jq -r '
      [
        .message,
        .error,
        .status,
        .errors[]?.message,
        .errors[]?
      ]
      | map(select(type == "string" and length > 0))
      | unique
      | join("; ")
    ' <<< "$response")"
    if [[ -n "$message" ]]; then
      echo "$message"
      return
    fi
    jq -c . <<< "$response"
    return
  fi
  printf '%s' "${response:-empty response}"
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
  response="$(grafana_curl \
    "$API/datasources/uid/$(url_encode "$PROM_DS_UID")")"
  existing_id="$(jq -r '.id // empty' <<< "$response")"

  if [[ -z "$existing_id" ]]; then
    response="$(grafana_curl \
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

ensure_prometheus_scrape_config() {
  local configure_script

  configure_script="${PROM_SCRAPE_CONFIG_SCRIPT:-$SCRIPT_DIR/configure-prometheus-scrape.sh}"
  if [[ ! -f "$configure_script" ]]; then
    echo "Prometheus scrape configurator not found: $configure_script" >&2
    exit 1
  fi

  PROM_CONFIG_HOST="$PROM_CONFIG_HOST" \
  PROM_CONFIG_FILE="$PROM_CONFIG_FILE" \
  PROM_RELOAD_URL="$PROM_RELOAD_URL" \
  PROM_SCRAPE_JOB_NAME="$PROM_SCRAPE_JOB_NAME" \
  PROM_SCRAPE_TARGETS="$PROM_SCRAPE_TARGETS" \
  PROM_SCRAPE_METRICS_PATH="$PROM_SCRAPE_METRICS_PATH" \
    bash "$configure_script"
}

ensure_folder() {
  local existing_uid query response created_uid status body

  # Prefer explicit folder UID if it already exists.
  existing_uid="$(
    grafana_curl "$API/folders/$FOLDER_UID" \
      | jq -r '.uid // empty' 2>/dev/null || true
  )"
  if [[ "$existing_uid" == "$FOLDER_UID" ]]; then
    echo "Using existing folder uid=$FOLDER_UID"
    return
  fi

  # Fall back to an existing folder title if present.
  query="$(url_encode "$FOLDER_TITLE")"
  existing_uid="$(
    grafana_curl "$API/search?type=dash-folder&query=$query" \
      | jq -r --arg t "$FOLDER_TITLE" '.[] | select(.title == $t) | .uid' 2>/dev/null \
      | head -n 1 || true
  )"

  if [[ -n "$existing_uid" ]]; then
    FOLDER_UID="$existing_uid"
    echo "Using existing folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
    return
  fi

  response="$(
    jq -cn --arg uid "$FOLDER_UID" --arg title "$FOLDER_TITLE" '{uid: $uid, title: $title}' \
      | curl_json_with_status -X POST "$API/folders" -d @-
  )"
  status="$(head -n 1 <<< "$response")"
  body="$(tail -n +2 <<< "$response")"

  created_uid="$(jq -r '.uid // empty' <<< "$body" 2>/dev/null || true)"
  if [[ -z "$created_uid" ]]; then
    if [[ "$status" == "409" || "$status" == "412" ]]; then
      existing_uid="$(
        grafana_curl "$API/folders/$FOLDER_UID" \
          | jq -r '.uid // empty' 2>/dev/null || true
      )"
      if [[ "$existing_uid" == "$FOLDER_UID" ]]; then
        echo "Using existing folder uid=$FOLDER_UID"
        return
      fi

      query="$(url_encode "$FOLDER_TITLE")"
      existing_uid="$(
        grafana_curl "$API/search?type=dash-folder&query=$query" \
          | jq -r --arg t "$FOLDER_TITLE" '.[] | select(.title == $t) | .uid' 2>/dev/null \
          | head -n 1 || true
      )"
      if [[ -n "$existing_uid" ]]; then
        FOLDER_UID="$existing_uid"
        echo "Using existing folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
        return
      fi
    fi

    echo "Failed to create Grafana folder \"$FOLDER_TITLE\" (HTTP $status): $(grafana_error_message "$body")" >&2
    exit 1
  fi

  FOLDER_UID="$created_uid"
  echo "Created folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
}

delete_dashboard_uid() {
  local uid="$1"
  local reason="${2:-dashboard}"
  echo "Deleting $reason uid=$uid"
  grafana_curl -X DELETE "$API/dashboards/uid/$uid" >/dev/null
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
  existing_uids="$(grafana_curl \
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
  grafana_curl \
    "$API/search?type=dash-db" | \
    jq -r --arg folder_uid "$FOLDER_UID" \
      '.[] | select(.folderUid == $folder_uid) | .uid' | \
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue

    # Double-check the dashboard actually belongs to our folder by fetching its metadata
    dashboard_data="$(grafana_curl "$API/dashboards/uid/$uid")"
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
if [[ "${SKIP_PROM_SCRAPE_CONFIG:-0}" != "1" ]]; then
  ensure_prometheus_scrape_config
fi
ensure_prometheus_datasource

for f in "${files[@]}"; do
  import_dashboard_file "$f"
done

delete_dashboards_missing_locally

echo "Done."
