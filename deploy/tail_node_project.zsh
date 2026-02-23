#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
SCRIPT_NAME="${0:t}"
CONFIG_FILE="$SCRIPT_DIR/config/node_projects.json"
PROJECT_MATCHER_LIB="$SCRIPT_DIR/lib/project_name_matcher.zsh"
TAIL_LINES="${TAIL_LINES:-100}"
ERRORS_ONLY=0

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
  echo "Usage: $SCRIPT_NAME [PROJECT_NAME [HOST]] [--lines N|-n N] [--errors-only|-e]" >&2
  echo "  If no parameters are provided, interactive mode is used." >&2
  echo "  HOST defaults to 'ocl' when omitted." >&2
}

list_projects() {
  echo "Available projects:"
  jq -r '.[].name' "$CONFIG_FILE" | nl -w2 -s'. '
}

project_exists() {
  local project_name="$1"
  jq -e --arg name "$project_name" '.[] | select(.name == $name)' "$CONFIG_FILE" >/dev/null
}

typeset -a POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--lines)
      flag="$1"
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: Missing value for $flag" >&2
        usage
        exit 1
      fi
      if [[ ! "$1" =~ ^[0-9]+$ || "$1" -lt 1 ]]; then
        echo "Error: --lines must be a positive integer (received: $1)" >&2
        exit 1
      fi
      TAIL_LINES="$1"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    -e|--errors-only|errors-only)
      ERRORS_ONLY=1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      ;;
  esac
  shift
done
set -- "${POSITIONAL_ARGS[@]}"

if [[ $# -eq 0 ]]; then
  echo "==> Interactive tail mode"
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
elif [[ $# -eq 1 ]]; then
  PROJECT_NAME="$1"
  HOST="ocl"
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

REMOTE_DIR="~/dev/${PROJECT_NAME}"
REMOTE_STDOUT_LOG="${REMOTE_DIR}/${PROJECT_NAME}.log"
REMOTE_STDERR_LOG="${REMOTE_DIR}/${PROJECT_NAME}.error.log"

echo "==> Tailing project logs"
echo "    Project: $PROJECT_NAME"
echo "    Remote host: $HOST"
echo "    Stdout log: $REMOTE_STDOUT_LOG"
echo "    Stderr log: $REMOTE_STDERR_LOG"
echo "    Lines: $TAIL_LINES"
echo "    Mode: $([[ "$ERRORS_ONLY" == "1" ]] && echo "errors only" || echo "stdout + stderr")"
echo "    Press Ctrl+C to stop."
echo ""

ssh -o ConnectTimeout=10 "$HOST" "
set -eu

REMOTE_DIR=\"$REMOTE_DIR\"
PROJECT_NAME=\"$PROJECT_NAME\"
TAIL_LINES=\"$TAIL_LINES\"

REMOTE_DIR_EXPANDED=\$(eval echo \"\$REMOTE_DIR\")
STDOUT_LOG=\"\$REMOTE_DIR_EXPANDED/\${PROJECT_NAME}.log\"
STDERR_LOG=\"\$REMOTE_DIR_EXPANDED/\${PROJECT_NAME}.error.log\"

mkdir -p \"\$REMOTE_DIR_EXPANDED\"
touch \"\$STDOUT_LOG\" \"\$STDERR_LOG\"
if [[ \"$ERRORS_ONLY\" == \"1\" ]]; then
  tail -n \"\$TAIL_LINES\" -f \"\$STDERR_LOG\"
else
  tail -n \"\$TAIL_LINES\" -f \"\$STDOUT_LOG\" \"\$STDERR_LOG\"
fi
"
