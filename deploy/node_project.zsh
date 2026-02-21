#!/usr/bin/env zsh
set -euo pipefail

# Deploy script for Node.js projects
# - Auto-detects entry file (prefers server.js, falls back to index.js)
# - Syncs files to remote server via rsync
# - Installs dependencies on server
# - Creates/updates launchd service for automatic startup
# - Restarts service with new code
# - Supports quick mode for code-only deploys (sync + restart only)

# ---- Config ----
SCRIPT_DIR="${0:a:h}"
CONFIG_FILE="$SCRIPT_DIR/config/node_projects.json"
BW_FOLDER_ID="${BW_FOLDER_ID:-7a5cbc24-a5c4-4d07-bbf3-b3f600e24660}"
BW_APPS_FIELD_NAME="${BW_APPS_FIELD_NAME:-Apps}"
BW_REMOTE_ENV_FILE_NAME="${BW_REMOTE_ENV_FILE_NAME:-.bw-secrets.env.sh}"
BW_ENV_SYNC="${BW_ENV_SYNC:-1}"
BW_SESSION_CACHE_ENABLED="${BW_SESSION_CACHE_ENABLED:-1}"
BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"
QUICK_MODE=0
TAIL_MODE=0
TAIL_ERRORS_ONLY=0

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Function to list available projects
list_projects() {
  echo "Available projects:"
  jq -r '.[].name' "$CONFIG_FILE" | nl -w2 -s'. '
}

# Function to get project path by name
get_project_path() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .path' "$CONFIG_FILE"
}

# Function to get project metrics port by name
get_project_metrics_port() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .metrics_port // 3010' "$CONFIG_FILE"
}

# Function to get project startup port by name (falls back to metrics port)
get_project_startup_port() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .startup_port // .metrics_port // 3010' "$CONFIG_FILE"
}

# Resolve aliases from config and fall back to original name when no alias exists
resolve_project_name() {
  local input_name="$1"
  jq -r --arg name "$input_name" '
    ([.[] | select(.name == $name or ((.aliases // []) | index($name) != null)) | .name][0]) // $name
  ' "$CONFIG_FILE"
}

sanitize_env_var_name() {
  local raw_name="$1"
  local sanitized_name
  sanitized_name="$(echo "$raw_name" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9_]+/_/g')"
  sanitized_name="$(echo "$sanitized_name" | sed -E 's/^([0-9])/_\1/; s/_+$//')"
  if [[ -z "$sanitized_name" ]]; then
    sanitized_name="BW_SECRET"
  fi
  echo "$sanitized_name"
}

have_valid_bw_session() {
  [[ -n "${BW_SESSION:-}" ]] || return 1
  bw list items --folderid "$BW_FOLDER_ID" --session "$BW_SESSION" >/dev/null 2>&1
}

cache_bw_session() {
  [[ "$BW_SESSION_CACHE_ENABLED" == "1" ]] || return 0
  [[ -n "${BW_SESSION:-}" ]] || return 0
  local cache_dir
  cache_dir="${BW_SESSION_CACHE_FILE:h}"
  mkdir -p "$cache_dir"
  umask 077
  printf '%s\n' "$BW_SESSION" > "$BW_SESSION_CACHE_FILE"
  chmod 600 "$BW_SESSION_CACHE_FILE"
}

clear_cached_bw_session() {
  [[ "$BW_SESSION_CACHE_ENABLED" == "1" ]] || return 0
  [[ -f "$BW_SESSION_CACHE_FILE" ]] || return 0
  rm -f "$BW_SESSION_CACHE_FILE"
}

load_cached_bw_session() {
  [[ "$BW_SESSION_CACHE_ENABLED" == "1" ]] || return 1
  [[ -f "$BW_SESSION_CACHE_FILE" ]] || return 1

  local cached_session
  cached_session="$(<"$BW_SESSION_CACHE_FILE")"
  [[ -n "$cached_session" ]] || return 1

  BW_SESSION="$cached_session"
  export BW_SESSION

  if have_valid_bw_session; then
    echo "==> Using cached Bitwarden session from ${BW_SESSION_CACHE_FILE}"
    return 0
  fi

  echo "==> Cached Bitwarden session is invalid; unlocking again..."
  clear_cached_bw_session
  return 1
}

ensure_bw_session() {
  if ! command -v bw >/dev/null 2>&1; then
    echo "Error: Bitwarden CLI 'bw' is required but was not found in PATH" >&2
    exit 1
  fi

  if have_valid_bw_session; then
    echo "==> Using existing Bitwarden session"
    return
  fi

  if load_cached_bw_session; then
    return
  fi

  if ! bw login --check >/dev/null 2>&1; then
    echo "==> Bitwarden login required (2FA prompt may appear)..."
    bw login
  fi

  echo "==> Unlocking Bitwarden vault..."
  BW_SESSION="$(bw unlock --raw)"
  export BW_SESSION

  if ! have_valid_bw_session; then
    echo "Error: Could not establish a valid Bitwarden session" >&2
    exit 1
  fi

  cache_bw_session
}

# Parse switches before positional args.
typeset -a POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    quick|--quick|-q)
      QUICK_MODE=1
      ;;
    tail|--tail|-t)
      TAIL_MODE=1
      ;;
    errors-only|--errors-only|-e)
      TAIL_ERRORS_ONLY=1
      ;;
    tail-errors|--tail-errors)
      TAIL_MODE=1
      TAIL_ERRORS_ONLY=1
      ;;
    *)
      POSITIONAL_ARGS+=("$arg")
      ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]}"

if [[ "$TAIL_ERRORS_ONLY" == "1" && "$TAIL_MODE" == "0" ]]; then
  TAIL_MODE=1
fi

# Interactive mode - no positional parameters provided
if [[ $# -eq 0 ]]; then
  echo "==> Interactive deployment mode"
  echo ""
  list_projects
  echo ""
  read "?Select project number or name: " project_input

  # Check if input is a number
  if [[ "$project_input" =~ ^[0-9]+$ ]]; then
    PROJECT_NAME=$(jq -r ".[$((project_input - 1))].name" "$CONFIG_FILE")
    if [[ "$PROJECT_NAME" == "null" || -z "$PROJECT_NAME" ]]; then
      echo "Error: Invalid project number" >&2
      exit 1
    fi
  else
    PROJECT_NAME="$project_input"
  fi

  echo ""
  read "?Enter target hostname [default: ocl]: " HOST

  if [[ -z "$HOST" ]]; then
    HOST="ocl"
  fi
elif [[ $# -eq 2 ]]; then
  # Manual mode - project name and host provided
  PROJECT_NAME="$1"
  HOST="$2"
else
  echo "Usage: $0 [PROJECT_NAME HOST] [--quick|-q|quick] [--tail|-t|tail] [--errors-only|-e|errors-only]" >&2
  echo "  If no parameters provided, interactive mode will be used" >&2
  echo "  --quick/-q/quick: sync files and restart service only (skip deps, Bitwarden, healthcheck, Grafana)" >&2
  echo "  --tail/-t/tail: tail remote stdout/stderr log files after deploy completes" >&2
  echo "  --errors-only/-e/errors-only: when tailing, only follow remote stderr log" >&2
  echo "  --tail-errors/tail-errors: shorthand for --tail --errors-only" >&2
  echo "" >&2
  list_projects >&2
  exit 1
fi

PROJECT_NAME="$(resolve_project_name "$PROJECT_NAME")"

# Get project configuration from config file
LOCAL_DIR=$(get_project_path "$PROJECT_NAME")
METRICS_PORT=$(get_project_metrics_port "$PROJECT_NAME")
STARTUP_PORT=$(get_project_startup_port "$PROJECT_NAME")

if [[ -z "$LOCAL_DIR" || "$LOCAL_DIR" == "null" ]]; then
  echo "Error: Project '$PROJECT_NAME' not found in config file" >&2
  echo "" >&2
  echo "To add a new project, update: $CONFIG_FILE" >&2
  echo "Add a JSON object with these fields:" >&2
  echo "  - name: canonical deploy name (used by this script and remote dir/service label)" >&2
  echo "  - aliases: optional array of alternate names that map to this project" >&2
  echo "  - path: absolute local path to the project directory" >&2
  echo "  - start_command: startup command (for documentation; script auto-detects server.js/index.js)" >&2
  echo "  - startup_port: app HTTP port used for post-deploy /healthcheck (optional; defaults to metrics_port)" >&2
  echo "  - metrics_port: app metrics port for observability integration" >&2
  echo "" >&2
  list_projects >&2
  exit 1
fi

# Expand tilde in path if present
LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"

REMOTE_DIR="~/dev/${PROJECT_NAME}"

# Generate service label based on project name
SERVICE_LABEL="com.${PROJECT_NAME}.api"

echo "==> Deploying project: $PROJECT_NAME"
echo "    Local path: $LOCAL_DIR"
echo "    Remote host: $HOST"
echo "    Remote path: $REMOTE_DIR"
echo "    Deploy mode: $([[ "$QUICK_MODE" == "1" ]] && echo "quick" || echo "full")"
echo "    Tail logs after deploy: $([[ "$TAIL_MODE" == "1" ]] && echo "yes" || echo "no")"
if [[ "$TAIL_MODE" == "1" ]]; then
  echo "    Tail mode: $([[ "$TAIL_ERRORS_ONLY" == "1" ]] && echo "errors only" || echo "stdout + stderr")"
fi
echo ""

if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "Local dir not found: $LOCAL_DIR" >&2
  exit 1
fi

echo "==> Checking if rsync is installed on remote host..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "command -v rsync >/dev/null 2>&1"; then
  echo "❌ Error: rsync is not installed on $HOST" >&2
  echo "" >&2
  echo "Please install rsync on the remote host:" >&2
  echo "  Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y rsync" >&2
  echo "  RHEL/CentOS:   sudo yum install -y rsync" >&2
  echo "  macOS:         rsync should be pre-installed" >&2
  exit 1
fi

echo "==> Ensuring remote directory exists..."
ssh "$HOST" "mkdir -p $REMOTE_DIR"

echo "==> Syncing files to ${HOST}:${REMOTE_DIR} ..."
# Notes:
# - --delete makes remote mirror local (be careful!)
# - Exclude node_modules, .git, logs, etc.
# - If you keep a production .env on the server, exclude it so it isn't overwritten.
rsync -az --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude '.DS_Store' \
  --exclude 'npm-debug.log' \
  --exclude 'yarn.lock' \
  --exclude 'pnpm-lock.yaml' \
  --exclude '.env' \
  --exclude "$BW_REMOTE_ENV_FILE_NAME" \
  --exclude '.start-with-bw-env.sh' \
  --exclude 'coverage' \
  --exclude 'dist' \
  --exclude '.next' \
  --exclude '.turbo' \
  --exclude '*.local' \
  "$LOCAL_DIR/" \
  "${HOST}:${REMOTE_DIR}/"

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping dependency install."
else
  echo "==> Installing deps on server..."
  ssh "$HOST" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'; \
    cd $REMOTE_DIR && \
    if [[ -f package-lock.json ]]; then
      npm ci --omit=dev
    else
      npm install --omit=dev
    fi"
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping Bitwarden env sync."
elif [[ "$BW_ENV_SYNC" == "1" ]]; then
  echo "==> Syncing Bitwarden-managed environment variables..."
  ensure_bw_session
  echo "==> Refreshing Bitwarden vault data..."
  bw sync --session "$BW_SESSION"

  bw_items_json="$(bw list items --folderid "$BW_FOLDER_ID" --session "$BW_SESSION")"
  matching_item_ids="$(
    echo "$bw_items_json" | jq -r --arg project "$PROJECT_NAME" --arg apps_field "$BW_APPS_FIELD_NAME" '
      def norm: ascii_downcase | gsub("^\\s+|\\s+$"; "");
      ($project | norm) as $project_norm
      | .[]?
      | .id as $id
      | ((.fields // [] | map(select((.name // "" | norm) == ($apps_field | norm))) | .[0].value) // "") as $apps
      | ($apps | split(",") | map(norm) | map(select(length > 0))) as $apps_tokens
      | select(
          $apps_tokens | any(. as $token | ($project_norm | contains($token)) or ($token | contains($project_norm)))
        )
      | $id
    '
  )"

  bw_env_file_local="$(mktemp "/tmp/${PROJECT_NAME}.bw-secrets.XXXXXX")"
  trap 'rm -f "$bw_env_file_local"' EXIT
  {
    echo "# Managed by deploy/node_project.zsh"
    echo "# Project: $PROJECT_NAME"
    echo "# Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$bw_env_file_local"

  matched_secret_count=0
  typeset -a matched_env_var_names=()
  while IFS= read -r item_id; do
    [[ -z "$item_id" ]] && continue
    item_json="$(bw get item "$item_id" --session "$BW_SESSION")"
    item_name="$(echo "$item_json" | jq -r '.name // empty')"
    item_value="$(echo "$item_json" | jq -r --arg apps_field "$BW_APPS_FIELD_NAME" '
      ([.fields[]?
        | select((.name // "" | ascii_downcase) != ($apps_field | ascii_downcase))
        | .value
        | select(. != null and . != "")
      ][0]) // (.login.password // "")
    ')"

    if [[ -z "$item_name" || -z "$item_value" ]]; then
      echo "   Skipping Bitwarden item $item_id (missing name/value)"
      continue
    fi

    env_var_name="$(sanitize_env_var_name "$item_name")"
    if [[ "$env_var_name" != "$item_name" ]]; then
      echo "   Normalized env var name '$item_name' -> '$env_var_name'"
    fi

    printf 'export %s=%q\n' "$env_var_name" "$item_value" >> "$bw_env_file_local"
    matched_env_var_names+=("$env_var_name")
    matched_secret_count=$((matched_secret_count + 1))
  done <<< "$matching_item_ids"

  if [[ "$matched_secret_count" -eq 0 ]]; then
    echo "   No matching Bitwarden items found for project '$PROJECT_NAME'"
  else
    echo "   Prepared $matched_secret_count Bitwarden env var(s) for '$PROJECT_NAME'"
    echo "   Environment variable names:"
    printf '     - %s\n' "${matched_env_var_names[@]}"
  fi

  REMOTE_BW_ENV_FILE="${REMOTE_DIR}/${BW_REMOTE_ENV_FILE_NAME}"
  rsync -az "$bw_env_file_local" "${HOST}:${REMOTE_BW_ENV_FILE}"
  ssh "$HOST" "chmod 600 ${REMOTE_BW_ENV_FILE}"
  echo "   Uploaded Bitwarden env file to ${HOST}:${REMOTE_BW_ENV_FILE}"
else
  echo "==> Skipping Bitwarden env sync (BW_ENV_SYNC=${BW_ENV_SYNC})"
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode: restarting existing service..."
  ssh "$HOST" "
    set -e
    REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)
    BW_ENV_FILE=\"\$REMOTE_DIR_EXPANDED/${BW_REMOTE_ENV_FILE_NAME}\"
    START_WRAPPER=\"\$REMOTE_DIR_EXPANDED/.start-with-bw-env.sh\"

    if [[ -f \"\$REMOTE_DIR_EXPANDED/server.js\" ]]; then
      ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/server.js\"
    elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.js\" ]]; then
      ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/index.js\"
    else
      echo \"Error: Neither server.js nor index.js found in \$REMOTE_DIR_EXPANDED\" >&2
      exit 1
    fi

    # Rebuild wrapper in quick mode since rsync --delete may have removed it.
    cat > \"\$START_WRAPPER\" << EOF_START_WRAPPER
#!/usr/bin/env bash
set -euo pipefail

if [[ -f \"\$BW_ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  source \"\$BW_ENV_FILE\"
fi

exec \"\$(command -v node)\" \"\$ENTRY_FILE\"
EOF_START_WRAPPER
    chmod 700 \"\$START_WRAPPER\"

    if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
      DOMAIN=\"gui/\$(id -u)\"
      if ! launchctl print \"\$DOMAIN/${SERVICE_LABEL}\" >/dev/null 2>&1; then
        echo \"Error: launchd service not found: ${SERVICE_LABEL}\" >&2
        echo \"Run a full deploy first to create/update service configuration.\" >&2
        exit 1
      fi
      launchctl kickstart -k \"\$DOMAIN/${SERVICE_LABEL}\"
      sleep 1
      if ! launchctl print \"\$DOMAIN/${SERVICE_LABEL}\" | grep -q 'state = running'; then
        echo \"Error: launchd service did not remain running: ${SERVICE_LABEL}\" >&2
        launchctl print \"\$DOMAIN/${SERVICE_LABEL}\" || true
        exit 1
      fi
      echo 'Service restarted via launchd'

    elif command -v systemctl >/dev/null 2>&1; then
      if ! systemctl --user status ${SERVICE_LABEL}.service >/dev/null 2>&1; then
        echo \"Error: systemd service not found: ${SERVICE_LABEL}.service\" >&2
        echo \"Run a full deploy first to create/update service configuration.\" >&2
        exit 1
      fi
      systemctl --user restart ${SERVICE_LABEL}.service
      sleep 1
      if ! systemctl --user is-active --quiet ${SERVICE_LABEL}.service; then
        echo \"Error: systemd service did not remain active: ${SERVICE_LABEL}.service\" >&2
        systemctl --user status ${SERVICE_LABEL}.service --no-pager || true
        exit 1
      fi
      echo 'Service restarted via systemd'

    else
      echo \"Error: Neither launchd nor systemd found. Cannot manage service.\" >&2
      exit 1
    fi
  "
else
  echo "==> Setting up and restarting service..."
  ssh "$HOST" "
    set -e
    REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)
    BW_ENV_FILE=\"\$REMOTE_DIR_EXPANDED/${BW_REMOTE_ENV_FILE_NAME}\"
    START_WRAPPER=\"\$REMOTE_DIR_EXPANDED/.start-with-bw-env.sh\"

    # Detect which entry file to use (server.js or index.js)
    if [[ -f \"\$REMOTE_DIR_EXPANDED/server.js\" ]]; then
      ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/server.js\"
      echo 'Using server.js as entry point'
    elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.js\" ]]; then
      ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/index.js\"
      echo 'Using index.js as entry point'
    else
      echo \"Error: Neither server.js nor index.js found in \$REMOTE_DIR_EXPANDED\" >&2
      exit 1
    fi

    cat > \"\$START_WRAPPER\" << EOF_START_WRAPPER
#!/usr/bin/env bash
set -euo pipefail

if [[ -f \"\$BW_ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  source \"\$BW_ENV_FILE\"
fi

exec \"\$(command -v node)\" \"\$ENTRY_FILE\"
EOF_START_WRAPPER
    chmod 700 \"\$START_WRAPPER\"
    echo \"Startup wrapper prepared at \$START_WRAPPER\"

    # Detect OS and use appropriate service manager
    if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
      echo \"==> Using launchd (macOS)\"
      PLIST=\"\$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist\"
      DOMAIN=\"gui/\$(id -u)\"

      # Create LaunchAgent directory if it doesn't exist
      mkdir -p \"\$HOME/Library/LaunchAgents\"

      # Create plist file
      cat > \"\$PLIST\" << 'EOF_PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key>
  <string>${SERVICE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>START_WRAPPER_PLACEHOLDER</string>
  </array>
  <key>WorkingDirectory</key>
  <string>REMOTE_DIR_PLACEHOLDER</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>REMOTE_DIR_PLACEHOLDER/${PROJECT_NAME}.log</string>
  <key>StandardErrorPath</key>
  <string>REMOTE_DIR_PLACEHOLDER/${PROJECT_NAME}.error.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF_PLIST

      # Replace placeholders
      sed -i '' \"s|REMOTE_DIR_PLACEHOLDER|\$REMOTE_DIR_EXPANDED|g\" \"\$PLIST\"
      sed -i '' \"s|START_WRAPPER_PLACEHOLDER|\$START_WRAPPER|g\" \"\$PLIST\"

      # Restart service
      launchctl bootout \"\$DOMAIN/$SERVICE_LABEL\" 2>/dev/null || true
      launchctl bootstrap \"\$DOMAIN\" \"\$PLIST\"
      launchctl enable \"\$DOMAIN/$SERVICE_LABEL\" || true
      launchctl kickstart -k \"\$DOMAIN/$SERVICE_LABEL\"
      echo 'Service restarted via launchd'

    elif command -v systemctl >/dev/null 2>&1; then
      echo \"==> Using systemd (Linux)\"
      SERVICE_FILE=\"\$HOME/.config/systemd/user/${SERVICE_LABEL}.service\"

      # Create systemd user directory
      mkdir -p \"\$HOME/.config/systemd/user\"

      # Create systemd service file
      cat > \"\$SERVICE_FILE\" << EOF_SYSTEMD
[Unit]
Description=${PROJECT_NAME} API Service
After=network.target

[Service]
Type=simple
WorkingDirectory=\$REMOTE_DIR_EXPANDED
ExecStart=START_WRAPPER_PLACEHOLDER
Restart=always
RestartSec=10
StandardOutput=append:\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}.log
StandardError=append:\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}.error.log
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF_SYSTEMD

      sed -i \"s|START_WRAPPER_PLACEHOLDER|\$START_WRAPPER|g\" \"\$SERVICE_FILE\"

      # Reload systemd, enable and restart service
      systemctl --user daemon-reload
      systemctl --user enable ${SERVICE_LABEL}.service
      systemctl --user restart ${SERVICE_LABEL}.service
      echo 'Service restarted via systemd'

      # Show service status
      systemctl --user status ${SERVICE_LABEL}.service --no-pager || true

    else
      echo \"Error: Neither launchd nor systemd found. Cannot manage service.\" >&2
      exit 1
    fi
  "
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping healthcheck verification."
else
  echo "==> Verifying service healthcheck..."
  HEALTHCHECK_URL="http://localhost:${STARTUP_PORT}/healthcheck"
  HEALTHCHECK_CMD="curl -sS --max-time 10 ${HEALTHCHECK_URL}"
  echo "   Debug command:"
  echo "   ssh ${HOST} '${HEALTHCHECK_CMD}'"

  healthcheck_ok=0
  healthcheck_last_output=""
  for attempt in {1..10}; do
    if healthcheck_last_output="$(ssh "$HOST" "$HEALTHCHECK_CMD" 2>&1)"; then
      if echo "$healthcheck_last_output" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
        healthcheck_ok=1
        break
      fi
    fi
    sleep 2
  done

  if [[ "$healthcheck_ok" -eq 1 ]]; then
    echo "✅ Healthcheck OK at ${HEALTHCHECK_URL}"
    echo "   Response: ${healthcheck_last_output}"
  else
    echo "❌ Healthcheck failed at ${HEALTHCHECK_URL}" >&2
    if [[ -n "$healthcheck_last_output" ]]; then
      echo "   Last output: ${healthcheck_last_output}" >&2
    fi
    exit 1
  fi
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping Grafana dashboard import."
else
  # Check for and run Grafana dashboard import script if it exists
  PROJECT_DASHBOARD_DIR="${GRAFANA_DASHBOARD_DIR:-$LOCAL_DIR/observability/grafana/dashboards}"
  LOCAL_DASHBOARD_SCRIPT="$LOCAL_DIR/observability/grafana/import-dashboards.sh"
  CENTRAL_DASHBOARD_SCRIPT="$SCRIPT_DIR/../monitoring/import-dashboards.sh"
  DASHBOARD_SCRIPT=""

  if [[ -n "${GRAFANA_IMPORT_SCRIPT:-}" ]]; then
    if [[ ! -f "$GRAFANA_IMPORT_SCRIPT" ]]; then
      echo "Error: GRAFANA_IMPORT_SCRIPT not found: $GRAFANA_IMPORT_SCRIPT" >&2
      exit 1
    fi
    DASHBOARD_SCRIPT="$GRAFANA_IMPORT_SCRIPT"
  elif [[ -f "$LOCAL_DASHBOARD_SCRIPT" ]]; then
    DASHBOARD_SCRIPT="$LOCAL_DASHBOARD_SCRIPT"
  elif [[ -f "$CENTRAL_DASHBOARD_SCRIPT" ]]; then
    DASHBOARD_SCRIPT="$CENTRAL_DASHBOARD_SCRIPT"
  fi

  if [[ -n "$DASHBOARD_SCRIPT" ]]; then
    if [[ ! -d "$PROJECT_DASHBOARD_DIR" ]]; then
      echo "==> Grafana dashboard directory not found (${PROJECT_DASHBOARD_DIR}), skipping..."
    else
      echo "==> Running Grafana dashboard import script..."
      echo "   Import script: ${DASHBOARD_SCRIPT}"
      echo "   Dashboard dir: ${PROJECT_DASHBOARD_DIR}"
      REMOTE_HOME="$(ssh "$HOST" "printf %s \"\$HOME\"")"

      # Prefer the actual mounted Prometheus config file path from the running container.
      AUTO_PROM_CONFIG_FILE="$(
        ssh "$HOST" "sudo docker inspect prometheus --format '{{range .Mounts}}{{if eq .Destination \"/etc/prometheus/prometheus.yml\"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true"
      )"
      if [[ -z "$AUTO_PROM_CONFIG_FILE" ]]; then
        AUTO_PROM_CONFIG_FILE="${REMOTE_HOME}/monitoring/prometheus.yml"
      fi

      # Prefer host primary IPv4 for scraping host services from containers.
      AUTO_PROM_HOST_IP="$(
        ssh "$HOST" "ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i==\"src\") {print \$(i+1); exit}}' || true"
      )"
      if [[ -z "$AUTO_PROM_HOST_IP" ]]; then
        AUTO_PROM_HOST_IP="$(
          ssh "$HOST" "hostname -I 2>/dev/null | awk '{print \$1}' || true"
        )"
      fi

      # Also detect Docker gateway as a fallback.
      AUTO_PROM_GW="$(
        ssh "$HOST" "sudo docker inspect prometheus --format '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' 2>/dev/null | awk '{print \$1}' || true"
      )"

      if [[ -n "$AUTO_PROM_HOST_IP" ]]; then
        AUTO_PROM_SCRAPE_TARGET="${AUTO_PROM_HOST_IP}:${METRICS_PORT}"
      elif [[ -n "$AUTO_PROM_GW" ]]; then
        AUTO_PROM_SCRAPE_TARGET="${AUTO_PROM_GW}:${METRICS_PORT}"
      else
        AUTO_PROM_SCRAPE_TARGET="host.docker.internal:${METRICS_PORT}"
      fi

      echo "   Prometheus config: ${AUTO_PROM_CONFIG_FILE}"
      echo "   Host IP candidate: ${AUTO_PROM_HOST_IP:-<none>}"
      echo "   Docker GW fallback: ${AUTO_PROM_GW:-<none>}"
      echo "   Prometheus scrape target: ${AUTO_PROM_SCRAPE_TARGET}"

      AUTO_PROM_SCRAPE_PORT="${AUTO_PROM_SCRAPE_TARGET##*:}"
      AUTO_PROM_NET_NAME="$(
        ssh "$HOST" "sudo docker inspect prometheus --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' 2>/dev/null | awk '{print \$1}' || true"
      )"
      AUTO_PROM_SUBNET=""
      if [[ -n "$AUTO_PROM_NET_NAME" ]]; then
        AUTO_PROM_SUBNET="$(
          ssh "$HOST" "sudo docker network inspect \"$AUTO_PROM_NET_NAME\" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true"
        )"
      fi
      if [[ -n "$AUTO_PROM_SUBNET" ]]; then
        echo "   Ensuring firewall allows ${AUTO_PROM_SUBNET} -> tcp/${AUTO_PROM_SCRAPE_PORT}"
        ssh "$HOST" "sudo iptables -C INPUT -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT"
      fi

      DEPLOY_HOST="$HOST" \
      PROJECT_NAME="$PROJECT_NAME" \
      METRICS_PORT="$METRICS_PORT" \
      DASHBOARD_DIR="$PROJECT_DASHBOARD_DIR" \
      PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-${AUTO_PROM_CONFIG_FILE}}" \
      PROM_SCRAPE_TARGET="${PROM_SCRAPE_TARGET:-${AUTO_PROM_SCRAPE_TARGET}}" \
        "$DASHBOARD_SCRIPT"
    fi
  else
    echo "==> No Grafana dashboard import script found (checked ${LOCAL_DASHBOARD_SCRIPT} and ${CENTRAL_DASHBOARD_SCRIPT}), skipping..."
  fi
fi

echo "✅ Deploy complete."

if [[ "$TAIL_MODE" == "1" ]]; then
  TAIL_SCRIPT="$SCRIPT_DIR/tail_node_project.zsh"
  if [[ ! -f "$TAIL_SCRIPT" ]]; then
    echo "Error: Tail script not found: $TAIL_SCRIPT" >&2
    exit 1
  fi

  echo "==> Starting log tail..."
  TAIL_ARGS=("$PROJECT_NAME" "$HOST")
  if [[ "$TAIL_ERRORS_ONLY" == "1" ]]; then
    TAIL_ARGS+=("--errors-only")
  fi
  zsh "$TAIL_SCRIPT" "${TAIL_ARGS[@]}"
fi
