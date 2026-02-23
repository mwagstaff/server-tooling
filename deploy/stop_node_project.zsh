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

get_project_and_alias_names() {
  local project_name="$1"
  jq -r --arg name "$project_name" '
    .[] | select(.name == $name) | ([.name] + (.aliases // []))[]
  ' "$CONFIG_FILE"
}

if [[ $# -eq 0 ]]; then
  echo "==> Interactive stop mode"
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

PROJECT_AND_ALIAS_NAMES=("${(@f)$(get_project_and_alias_names "$PROJECT_NAME")}")
if [[ ${#PROJECT_AND_ALIAS_NAMES[@]} -eq 0 ]]; then
  PROJECT_AND_ALIAS_NAMES=("$PROJECT_NAME")
fi
typeset -U PROJECT_AND_ALIAS_NAMES

SERVICE_LABELS=()
for name in "${PROJECT_AND_ALIAS_NAMES[@]}"; do
  SERVICE_LABELS+=("com.${name}.api")
done
typeset -U SERVICE_LABELS

PROJECT_NAME_REGEX="${(j:|:)PROJECT_AND_ALIAS_NAMES}"
PROCESS_REGEX="/dev/(.*/)?(${PROJECT_NAME_REGEX})/(server|index)\\.js"

echo "==> Stopping project: $PROJECT_NAME"
echo "    Remote host: $HOST"
echo "    Service labels:"
for service_label in "${SERVICE_LABELS[@]}"; do
  echo "      - $service_label"
done
echo ""

for SERVICE_LABEL in "${SERVICE_LABELS[@]}"; do
  SERVICE_UNIT="${SERVICE_LABEL}.service"
  echo "==> Stopping service label: $SERVICE_LABEL"
  ssh -o ConnectTimeout=10 "$HOST" "
set -eu
SERVICE_LABEL='$SERVICE_LABEL'
SERVICE_UNIT='$SERVICE_UNIT'

if command -v launchctl >/dev/null 2>&1; then
  UID_NUM=\"\$(id -u)\"
  echo \"Detected launchd (macOS) for \$SERVICE_LABEL.\"

  for DOMAIN in \"gui/\$UID_NUM\" \"user/\$UID_NUM\"; do
    if ! launchctl print \"\$DOMAIN\" >/dev/null 2>&1; then
      continue
    fi

    echo \"Stopping in launchd domain: \$DOMAIN\"
    launchctl disable \"\$DOMAIN/$SERVICE_LABEL\" || true
    launchctl bootout \"\$DOMAIN/$SERVICE_LABEL\" 2>/dev/null || true

    if launchctl print \"\$DOMAIN/$SERVICE_LABEL\" >/dev/null 2>&1; then
      echo \"Service still loaded in \$DOMAIN; retrying bootout...\"
      launchctl bootout \"\$DOMAIN/$SERVICE_LABEL\" 2>/dev/null || true
    fi
  done

  still_loaded=0
  for DOMAIN in \"gui/\$UID_NUM\" \"user/\$UID_NUM\"; do
    if launchctl print \"\$DOMAIN/$SERVICE_LABEL\" >/dev/null 2>&1; then
      echo \"Service still loaded in \$DOMAIN\" >&2
      still_loaded=1
    fi
  done

  if [[ \"\$still_loaded\" -eq 1 ]]; then
    echo 'Final state: loaded' >&2
    exit 1
  fi

  echo 'Final state: not loaded'
elif command -v systemctl >/dev/null 2>&1; then
  echo \"Detected systemd (Linux) for \$SERVICE_LABEL.\"

  echo 'Disabling service auto-start...'
  systemctl --user disable '$SERVICE_UNIT' || true

  echo 'Stopping service (non-blocking)...'
  systemctl --user stop --no-block '$SERVICE_UNIT' || true

  echo 'Waiting for service to stop (up to 20s)...'
  for _ in \$(seq 1 20); do
    state=\$(systemctl --user is-active '$SERVICE_UNIT' 2>/dev/null || true)
    if [[ \"\$state\" != 'active' && \"\$state\" != 'activating' ]]; then
      break
    fi
    sleep 1
  done

  final_state=\$(systemctl --user is-active '$SERVICE_UNIT' 2>/dev/null || true)
  if [[ \"\$final_state\" == 'active' || \"\$final_state\" == 'activating' ]]; then
    echo \"Service state is still '\$final_state'; sending SIGTERM...\"
    systemctl --user kill --signal=TERM '$SERVICE_UNIT' || true
    sleep 2
    final_state=\$(systemctl --user is-active '$SERVICE_UNIT' 2>/dev/null || true)
  fi

  echo \"Final state: \${final_state:-unknown}\"
  systemctl --user status '$SERVICE_UNIT' --no-pager || true
else
  echo 'Error: Neither launchctl nor systemctl is available on this host.' >&2
  exit 1
fi
"
done

echo ""
echo "==> Ensuring no matching Node processes remain..."
ssh -o ConnectTimeout=10 "$HOST" "
set -eu
PROCESS_REGEX='$PROCESS_REGEX'

if ! command -v pgrep >/dev/null 2>&1; then
  echo 'Warning: pgrep not available; skipping process fallback check.' >&2
  exit 0
fi

PIDS=\$(pgrep -f \"\$PROCESS_REGEX\" || true)
if [[ -n \"\$PIDS\" ]]; then
  echo 'Found matching Node process IDs:'
  echo \"\$PIDS\"
  kill \$PIDS || true
  sleep 1
fi

REMAINING=\$(pgrep -f \"\$PROCESS_REGEX\" || true)
if [[ -n \"\$REMAINING\" ]]; then
  echo 'Processes still running after SIGTERM; sending SIGKILL...'
  echo \"\$REMAINING\"
  kill -9 \$REMAINING || true
  sleep 1
fi

FINAL=\$(pgrep -f \"\$PROCESS_REGEX\" || true)
if [[ -n \"\$FINAL\" ]]; then
  echo 'Error: matching Node processes are still running:' >&2
  echo \"\$FINAL\" >&2
  exit 1
fi

echo 'No matching Node processes running.'
"

echo ""
echo "✅ Stopped and disabled project $PROJECT_NAME on $HOST"
