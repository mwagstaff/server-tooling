#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
CONFIG_FILE="$SCRIPT_DIR/config/node_projects.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

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

resolve_project_name() {
  local input_name="$1"
  jq -r --arg name "$input_name" '
    ([.[] | select(.name == $name or ((.aliases // []) | index($name) != null)) | .name][0]) // $name
  ' "$CONFIG_FILE"
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

PROJECT_NAME="$(resolve_project_name "$PROJECT_NAME")"

if ! project_exists "$PROJECT_NAME"; then
  echo "Error: Project '$PROJECT_NAME' not found in config file: $CONFIG_FILE" >&2
  echo ""
  list_projects >&2
  exit 1
fi

SERVICE_UNIT="com.${PROJECT_NAME}.api.service"

echo "==> Starting project: $PROJECT_NAME"
echo "    Remote host: $HOST"
echo "    Service unit: $SERVICE_UNIT"
echo ""

ssh "$HOST" "
set -euo pipefail
if ! command -v systemctl >/dev/null 2>&1; then
  echo 'Error: systemctl is not available on this host.' >&2
  exit 1
fi

systemctl --user daemon-reload
systemctl --user enable --now '$SERVICE_UNIT'
systemctl --user status '$SERVICE_UNIT' --no-pager || true
"

echo ""
echo "✅ Started and enabled $SERVICE_UNIT on $HOST"
