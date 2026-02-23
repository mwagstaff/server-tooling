#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
CONFIG_FILE="$SCRIPT_DIR/config/node_projects.json"
PROJECT_MATCHER_LIB="$SCRIPT_DIR/lib/project_name_matcher.zsh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_MATCHER_LIB" ]]; then
  echo "Error: Project matcher library not found: $PROJECT_MATCHER_LIB" >&2
  exit 1
fi
source "$PROJECT_MATCHER_LIB"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not found in PATH" >&2
  exit 1
fi

usage() {
  echo "Usage: $0 [PROJECT_NAME HOST]" >&2
  echo "  If no parameters are provided, interactive mode is used." >&2
}

list_projects() {
  echo "Available projects:"
  jq -r '.[].name' "$CONFIG_FILE" | nl -w2 -s'. '
}

project_exists() {
  local project_name="$1"
  jq -e --arg name "$project_name" '.[] | select(.name == $name)' "$CONFIG_FILE" >/dev/null
}

if [[ $# -eq 0 ]]; then
  echo "==> Interactive start mode"
  echo ""
  list_projects
  echo ""
  read "?Select project number or name: " project_input

  if [[ "$project_input" =~ ^[0-9]+$ ]]; then
    PROJECT_NAME="$(jq -r ".[$((project_input - 1))].name" "$CONFIG_FILE")"
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
  PROJECT_NAME="$1"
  HOST="$2"
else
  usage
  echo ""
  list_projects >&2
  exit 1
fi

if ! PROJECT_NAME="$(project_match_resolve_name "$CONFIG_FILE" "$PROJECT_NAME")"; then
  exit 1
fi

if ! project_exists "$PROJECT_NAME"; then
  echo "Error: Project '$PROJECT_NAME' not found in config file: $CONFIG_FILE" >&2
  echo ""
  list_projects >&2
  exit 1
fi

SERVICE_LABEL="com.${PROJECT_NAME}.api"
SERVICE_UNIT="${SERVICE_LABEL}.service"

echo "==> Starting project: $PROJECT_NAME"
echo "    Remote host: $HOST"
echo "    Service label: $SERVICE_LABEL"
echo "    Service unit: $SERVICE_UNIT"
echo ""

ssh -o ConnectTimeout=10 "$HOST" "
set -eu

if command -v launchctl >/dev/null 2>&1; then
  UID_NUM=\"\$(id -u)\"
  DOMAIN=''
  if launchctl print \"gui/\$UID_NUM\" >/dev/null 2>&1; then
    DOMAIN=\"gui/\$UID_NUM\"
  elif launchctl print \"user/\$UID_NUM\" >/dev/null 2>&1; then
    DOMAIN=\"user/\$UID_NUM\"
  else
    echo 'Error: Could not find a usable launchd domain for this user.' >&2
    exit 1
  fi

  PLIST=\"\$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist\"

  if [[ ! -f \"\$PLIST\" ]]; then
    echo \"Error: launchd plist not found: \$PLIST\" >&2
    exit 1
  fi

  echo \"Detected launchd (macOS). Using domain: \$DOMAIN\"

  # Clear out any previous load in either common user domain before starting.
  launchctl bootout \"gui/\$UID_NUM/$SERVICE_LABEL\" 2>/dev/null || true
  launchctl bootout \"user/\$UID_NUM/$SERVICE_LABEL\" 2>/dev/null || true

  launchctl bootstrap \"\$DOMAIN\" \"\$PLIST\"
  launchctl enable \"\$DOMAIN/$SERVICE_LABEL\" || true
  launchctl kickstart -k \"\$DOMAIN/$SERVICE_LABEL\"

  if launchctl print \"\$DOMAIN/$SERVICE_LABEL\" >/dev/null 2>&1; then
    echo 'Final state: loaded'
  else
    echo 'Error: Service is not loaded after start.' >&2
    exit 1
  fi
elif command -v systemctl >/dev/null 2>&1; then
  echo 'Detected systemd (Linux).'
  systemctl --user daemon-reload
  systemctl --user enable --now '$SERVICE_UNIT'
  systemctl --user status '$SERVICE_UNIT' --no-pager || true
else
  echo 'Error: Neither launchctl nor systemctl is available on this host.' >&2
  exit 1
fi
"

echo ""
echo "✅ Started and enabled $SERVICE_LABEL on $HOST"
