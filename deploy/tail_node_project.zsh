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

get_project_log_files() {
  local project_name="$1"
  local errors_only="$2"
  jq -r --arg name "$project_name" --arg errors_only "$errors_only" '
    .[] | select(.name == $name) as $project |
    if (($project.services // []) | length) > 0 then
      $project.services[]
      | if $errors_only == "1" then
          .error_log_file // (
            if ((.name // "api") == "api") then
              "\($project.name).error.log"
            else
              "\($project.name)-\(.name).error.log"
            end
          )
        else
          (.log_file // (
            if ((.name // "api") == "api") then
              "\($project.name).log"
            else
              "\($project.name)-\(.name).log"
            end
          )),
          (.error_log_file // (
            if ((.name // "api") == "api") then
              "\($project.name).error.log"
            else
              "\($project.name)-\(.name).error.log"
            end
          ))
        end
    else
      if $errors_only == "1" then
        .error_log_file // "\($project.name).error.log"
      else
        (.log_file // "\($project.name).log"),
        (.error_log_file // "\($project.name).error.log")
      end
    end
  ' "$CONFIG_FILE"
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
REMOTE_LOG_FILES=("${(@f)$(get_project_log_files "$PROJECT_NAME" "$ERRORS_ONLY")}")

echo "==> Tailing project logs"
echo "    Project: $PROJECT_NAME"
echo "    Remote host: $HOST"
echo "    Logs:"
for remote_log_file in "${REMOTE_LOG_FILES[@]}"; do
  echo "      - ${REMOTE_DIR}/${remote_log_file}"
done
echo "    Lines: $TAIL_LINES"
echo "    Mode: $([[ "$ERRORS_ONLY" == "1" ]] && echo "errors only" || echo "stdout + stderr")"
echo "    Controls: r = quick redeploy, f = full redeploy, Ctrl+C = stop."
echo ""

REMOTE_LOG_FILES_SSH="${(j: :)REMOTE_LOG_FILES}"

ssh -o ConnectTimeout=10 "$HOST" "
set -eu

REMOTE_DIR=\"$REMOTE_DIR\"
TAIL_LINES=\"$TAIL_LINES\"
REMOTE_LOG_FILES=(${REMOTE_LOG_FILES_SSH})

REMOTE_DIR_EXPANDED=\$(eval echo \"\$REMOTE_DIR\")

mkdir -p \"\$REMOTE_DIR_EXPANDED\"
TAIL_TARGETS=()
for log_name in \"\${REMOTE_LOG_FILES[@]}\"; do
  [[ -n \"\$log_name\" ]] || continue
  log_path=\"\$REMOTE_DIR_EXPANDED/\$log_name\"
  touch \"\$log_path\"
  TAIL_TARGETS+=(\"\$log_path\")
done

if [[ \"\${#TAIL_TARGETS[@]}\" -eq 0 ]]; then
  echo 'Error: no log files configured for this project.' >&2
  exit 1
fi

tail -n \"\$TAIL_LINES\" -f \"\${TAIL_TARGETS[@]}\"
"
