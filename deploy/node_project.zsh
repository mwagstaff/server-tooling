#!/usr/bin/env zsh
set -euo pipefail

# Deploy script for Node.js projects
# - Auto-detects entry file (server.js/server.mjs, falls back to index.js/index.mjs)
# - Syncs files to remote server via rsync
# - Installs dependencies on server
# - Creates/updates launchd service for automatic startup
# - Restarts service with new code
# - Supports quick mode for code-only deploys (sync + restart only)
# - Applies Bitwarden-managed credentials only when requested with bw/--bw

# ---- Config ----
SCRIPT_DIR="${0:a:h}"
SCRIPT_PATH="${0:a}"
CONFIG_FILE="$SCRIPT_DIR/config/node_projects.json"
PROJECT_MATCHER_LIB="$SCRIPT_DIR/lib/project_name_matcher.zsh"
BW_FOLDER_ID="${BW_FOLDER_ID:-7a5cbc24-a5c4-4d07-bbf3-b3f600e24660}"
BW_APPS_FIELD_NAME="${BW_APPS_FIELD_NAME:-Apps}"
BW_REMOTE_ENV_FILE_NAME="${BW_REMOTE_ENV_FILE_NAME:-.bw-secrets.env.sh}"
BW_ENV_SYNC="${BW_ENV_SYNC:-0}"
BW_SESSION_CACHE_ENABLED="${BW_SESSION_CACHE_ENABLED:-1}"
BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"
BW_SYNC_TTL_SECONDS="${BW_SYNC_TTL_SECONDS:-900}"
BW_SYNC_CACHE_FILE="${BW_SYNC_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-last-sync}"
BW_FORCE_SYNC="${BW_FORCE_SYNC:-0}"
BW_SKIP_SYNC="${BW_SKIP_SYNC:-0}"
QUICK_MODE=0
TAIL_MODE=0
TAIL_ERRORS_ONLY=0
DISABLE_MODE=0

# Check if config file exists
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

get_project_build_command() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .build_command // empty' "$CONFIG_FILE"
}

get_project_remote_dir() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .remote_dir // empty' "$CONFIG_FILE"
}

get_project_static_env() {
  local project_name="$1"
  jq -r --arg name "$project_name" '
    .[] | select(.name == $name) | .static_env // {} |
    to_entries[] | "export \(.key)=\(.value | @sh)"
  ' "$CONFIG_FILE"
}

get_project_bw_remote_env_file_name() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .bw_remote_env_file_name // empty' "$CONFIG_FILE"
}

project_package_has_script() {
  local project_dir="$1"
  local script_name="$2"
  local package_json="$project_dir/package.json"
  [[ -f "$package_json" ]] || return 1
  jq -e --arg script_name "$script_name" '(.scripts[$script_name]? // "") != ""' "$package_json" >/dev/null
}

project_uses_vite() {
  local project_dir="$1"
  local package_json="$project_dir/package.json"
  [[ -f "$package_json" ]] || return 1
  jq -e '
    (.dependencies.vite? // .devDependencies.vite? // .optionalDependencies.vite? // .peerDependencies.vite?) != null
    or ((.scripts.build? // "") | test("(^|[[:space:]])vite([[:space:]]|$)"))
  ' "$package_json" >/dev/null
}

project_build_runs_prepare_assets() {
  local project_dir="$1"
  local package_json="$project_dir/package.json"
  [[ -f "$package_json" ]] || return 1
  jq -e '(.scripts.build? // "") | test("prepare-assets")' "$package_json" >/dev/null
}

get_project_service_label() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .service_label // empty' "$CONFIG_FILE"
}

get_project_service_description() {
  local project_name="$1"
  jq -r --arg name "$project_name" '.[] | select(.name == $name) | .service_description // empty' "$CONFIG_FILE"
}

get_project_legacy_service_labels() {
  local project_name="$1"
  jq -r --arg name "$project_name" '
    .[] | select(.name == $name) as $project |
    (
      ($project.legacy_service_labels // [])
      + ((($project.services // []) | map(.legacy_service_labels // []) | add) // [])
    )[]
  ' "$CONFIG_FILE"
}

get_project_and_alias_names() {
  local project_name="$1"
  jq -r --arg name "$project_name" '
    .[] | select(.name == $name) | ([.name] + (.aliases // []))[]
  ' "$CONFIG_FILE"
}

get_project_services_json() {
  local project_name="$1"
  jq -c --arg name "$project_name" '
    .[] | select(.name == $name) as $project |
    if (($project.services // []) | length) > 0 then
      $project.services | map(
        . as $service |
        {
          name: ($service.name // "api"),
          service_label: (
            $service.service_label
            // (
              if (($service.name // "api") == "api") then
                ($project.service_label // "com.\($project.name).api")
              else
                "com.\($project.name).\($service.name)"
              end
            )
          ),
          service_description: (
            $service.service_description
            // (
              if (($service.name // "api") == "api") then
                ($project.service_description // "\($project.name) API Service")
              else
                "\($project.name) \($service.name) Service"
              end
            )
          ),
          entry_file: ($service.entry_file // ""),
          startup_port: ($service.startup_port // ""),
          metrics_port: ($service.metrics_port // ""),
          log_file: (
            $service.log_file
            // (
              if (($service.name // "api") == "api") then
                "\($project.name).log"
              else
                "\($project.name)-\($service.name).log"
              end
            )
          ),
          error_log_file: (
            $service.error_log_file
            // (
              if (($service.name // "api") == "api") then
                "\($project.name).error.log"
              else
                "\($project.name)-\($service.name).error.log"
              end
            )
          )
        }
      )
    else
      [
        {
          name: "api",
          service_label: ($project.service_label // "com.\($project.name).api"),
          service_description: ($project.service_description // "\($project.name) API Service"),
          entry_file: ($project.entry_file // ""),
          startup_port: ($project.startup_port // $project.metrics_port // ""),
          metrics_port: ($project.metrics_port // ""),
          log_file: ($project.log_file // "\($project.name).log"),
          error_log_file: ($project.error_log_file // "\($project.name).error.log")
        }
      ]
    end
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

sanitize_grafana_slug() {
  local raw_name="$1"
  local slug
  slug="$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$slug" ]]; then
    slug="project"
  fi
  echo "$slug"
}

find_free_local_port() {
  local port
  for port in {32100..32199}; do
    if command -v lsof >/dev/null 2>&1; then
      if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "$port"
        return 0
      fi
    elif command -v nc >/dev/null 2>&1; then
      if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "$port"
        return 0
      fi
    else
      echo "$port"
      return 0
    fi
  done
  return 1
}

have_valid_bw_session() {
  [[ -n "${BW_SESSION:-}" ]] || return 1
  local bw_vault_status
  bw_vault_status="$(bw --nointeraction --session "$BW_SESSION" status 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" || return 1
  [[ "$bw_vault_status" == "unlocked" ]]
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

bw_sync_cache_is_fresh() {
  [[ -f "$BW_SYNC_CACHE_FILE" ]] || return 1
  [[ "$BW_SYNC_TTL_SECONDS" =~ '^[0-9]+$' ]] || return 1
  [[ "$BW_SYNC_TTL_SECONDS" -gt 0 ]] || return 1

  local now cache_mtime age
  now="$(date +%s)"
  if stat -f %m "$BW_SYNC_CACHE_FILE" >/dev/null 2>&1; then
    cache_mtime="$(stat -f %m "$BW_SYNC_CACHE_FILE")"
  else
    cache_mtime="$(stat -c %Y "$BW_SYNC_CACHE_FILE" 2>/dev/null)" || return 1
  fi

  age=$((now - cache_mtime))
  [[ "$age" -ge 0 && "$age" -lt "$BW_SYNC_TTL_SECONDS" ]]
}

mark_bw_sync_cache_fresh() {
  local cache_dir
  cache_dir="${BW_SYNC_CACHE_FILE:h}"
  mkdir -p "$cache_dir"
  : > "$BW_SYNC_CACHE_FILE"
}

refresh_bw_vault_data_if_needed() {
  if [[ "$BW_SKIP_SYNC" == "1" ]]; then
    echo "==> Skipping Bitwarden vault refresh (BW_SKIP_SYNC=1)"
    return 0
  fi

  if [[ "$BW_FORCE_SYNC" != "1" ]] && bw_sync_cache_is_fresh; then
    echo "==> Using recently refreshed Bitwarden vault data (BW_SYNC_TTL_SECONDS=${BW_SYNC_TTL_SECONDS})"
    return 0
  fi

  echo "==> Refreshing Bitwarden vault data..."
  run_bw_with_session sync >/dev/null
  mark_bw_sync_cache_fresh
}

bw_output_indicates_session_issue() {
  local output="$1"
  [[ "$output" == *"Vault is locked"* ]] \
    || [[ "$output" == *"You are not logged in"* ]] \
    || [[ "$output" == *"session"* && "$output" == *"expired"* ]] \
    || [[ "$output" == *"session"* && "$output" == *"invalid"* ]] \
    || [[ "$output" == *"Master password"* ]] \
    || [[ "$output" == *"The decryption operation failed"* ]] \
    || [[ "$output" == *"The provided key is not the expected type"* ]]
}

run_bw_with_session() {
  local output bw_command_status attempt

  for attempt in 1 2; do
    output="$(bw --nointeraction --session "$BW_SESSION" "$@" 2>&1)" && {
      printf '%s\n' "$output"
      return 0
    }
    bw_command_status=$?

    if [[ "$attempt" -eq 1 ]] && bw_output_indicates_session_issue "$output"; then
      echo "==> Bitwarden session became invalid; unlocking again..."
      clear_cached_bw_session
      unset BW_SESSION
      ensure_bw_session
      continue
    fi

    printf '%s\n' "$output" >&2
    return "$bw_command_status"
  done

  return 1
}

escape_json_string_control_chars() {
  perl -0777 -ne '
    my $out = "";
    my $in_string = 0;
    my $escaped = 0;

    for (my $i = 0; $i < length($_); $i++) {
      my $ch = substr($_, $i, 1);
      my $ord = ord($ch);

      if ($in_string) {
        if ($escaped) {
          $out .= $ch;
          $escaped = 0;
          next;
        }

        if ($ch eq "\\") {
          $out .= $ch;
          $escaped = 1;
          next;
        }

        if ($ch eq "\"") {
          $out .= $ch;
          $in_string = 0;
          next;
        }

        if ($ord <= 0x1f) {
          if ($ch eq "\n") {
            $out .= "\\n";
          } elsif ($ch eq "\r") {
            $out .= "\\r";
          } elsif ($ch eq "\t") {
            $out .= "\\t";
          } elsif ($ch eq "\f") {
            $out .= "\\f";
          } elsif ($ch eq "\b") {
            $out .= "\\b";
          } else {
            $out .= sprintf("\\u%04x", $ord);
          }
          next;
        }
      } elsif ($ch eq "\"") {
        $in_string = 1;
      }

      $out .= $ch;
    }

    print $out;
  '
}

run_bw_json_with_session() {
  local output sanitized

  output="$(run_bw_with_session "$@")"
  if printf '%s' "$output" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$output"
    return 0
  fi

  if ! command -v perl >/dev/null 2>&1; then
    echo "Error: Bitwarden CLI returned invalid JSON and perl is required to sanitize it" >&2
    return 1
  fi

  sanitized="$(printf '%s' "$output" | escape_json_string_control_chars)"
  if printf '%s' "$sanitized" | jq -e . >/dev/null 2>&1; then
    echo "   Warning: Bitwarden returned JSON with unescaped control characters; sanitized before parsing." >&2
    printf '%s\n' "$sanitized"
    return 0
  fi

  echo "Error: Bitwarden CLI returned invalid JSON for: bw $*" >&2
  echo "       Try 'bw sync' or clear the cached session: rm -f ${BW_SESSION_CACHE_FILE}" >&2
  return 1
}

ensure_remote_port_available() {
  local host="$1"
  local port="$2"
  local service_label="${3:-}"

  if [[ -z "$port" || "$port" == "null" ]]; then
    echo "==> Startup port not configured; skipping port cleanup."
    return 0
  fi

  echo "==> Ensuring port ${port} is free before restart..."
  ssh "$host" "
    set -eu
    TARGET_PORT='$port'
    SERVICE_LABEL='$service_label'
    SERVICE_UNIT=''
    if [[ -n \"\$SERVICE_LABEL\" ]]; then
      SERVICE_UNIT=\"\$SERVICE_LABEL.service\"
    fi

    get_listening_pids() {
      if command -v lsof >/dev/null 2>&1; then
        lsof -nP -tiTCP:\"\$TARGET_PORT\" -sTCP:LISTEN 2>/dev/null || true
      elif command -v fuser >/dev/null 2>&1; then
        fuser -n tcp \"\$TARGET_PORT\" 2>/dev/null | tr ' ' '\n' || true
      elif command -v ss >/dev/null 2>&1; then
        ss -ltnp \"( sport = :\$TARGET_PORT )\" 2>/dev/null | sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' || true
      else
        echo \"Warning: could not inspect port \$TARGET_PORT because lsof, fuser, and ss are unavailable.\" >&2
        return 0
      fi | awk 'NF {print \$1}' | sort -u
    }

    systemd_unit_exists() {
      local unit=\"\$1\"
      [[ -n \"\$unit\" ]] || return 1
      [[ \"\$(systemctl --user show \"\$unit\" --property=LoadState --value 2>/dev/null || true)\" == 'loaded' ]]
    }

    systemd_unit_active_state() {
      local unit=\"\$1\"
      [[ -n \"\$unit\" ]] || return 1
      systemctl --user show \"\$unit\" --property=ActiveState --value 2>/dev/null || true
    }

    print_listening_processes() {
      local pids=\"\$1\"
      if [[ -n \"\$pids\" ]] && command -v ps >/dev/null 2>&1; then
        ps -fp \$pids || true
      fi
    }

    wait_for_listener_exit() {
      local attempts=\"\$1\"
      local remaining_pids=''
      local attempt=0
      while [[ \"\$attempt\" -lt \"\$attempts\" ]]; do
        remaining_pids=\"\$(get_listening_pids)\"
        if [[ -z \"\$remaining_pids\" ]]; then
          return 0
        fi
        attempt=\$((attempt + 1))
        sleep 1
      done
      [[ -z \"\$(get_listening_pids)\" ]]
    }

    stop_systemd_service_if_needed() {
      local active_state=''
      [[ -n \"\$SERVICE_UNIT\" ]] || return 0
      command -v systemctl >/dev/null 2>&1 || return 0
      systemd_unit_exists \"\$SERVICE_UNIT\" || return 0
      active_state=\"\$(systemd_unit_active_state \"\$SERVICE_UNIT\")\"
      [[ \"\$active_state\" == 'active' || \"\$active_state\" == 'activating' || \"\$active_state\" == 'deactivating' || \"\$active_state\" == 'reloading' ]] || return 0

      echo \"Stopping systemd service \$SERVICE_UNIT before freeing port \$TARGET_PORT...\"
      systemctl --user reset-failed \"\$SERVICE_UNIT\" >/dev/null 2>&1 || true
      systemctl --user stop --no-block \"\$SERVICE_UNIT\" >/dev/null 2>&1 || true

      if wait_for_listener_exit 15; then
        active_state=\"\$(systemd_unit_active_state \"\$SERVICE_UNIT\")\"
        if [[ \"\$active_state\" == 'deactivating' ]]; then
          echo \"Systemd service \$SERVICE_UNIT is still deactivating, but port \$TARGET_PORT is free.\"
        fi
        return 0
      fi

      echo \"Systemd service \$SERVICE_UNIT did not stop cleanly; forcing termination...\"
      systemctl --user kill --kill-who=all --signal=SIGTERM \"\$SERVICE_UNIT\" >/dev/null 2>&1 || true
      if wait_for_listener_exit 3; then
        return 0
      fi
      systemctl --user kill --kill-who=all --signal=SIGKILL \"\$SERVICE_UNIT\" >/dev/null 2>&1 || true
      systemctl --user stop --no-block \"\$SERVICE_UNIT\" >/dev/null 2>&1 || true

      if wait_for_listener_exit 5; then
        return 0
      fi

      echo \"Systemd service \$SERVICE_UNIT is still not fully stopped.\" >&2
      systemctl --user status \"\$SERVICE_UNIT\" --no-pager >&2 || true
      return 1
    }

    PIDS=\"\$(get_listening_pids)\"
    if [[ -z \"\$PIDS\" ]]; then
      echo \"No existing listeners found on port \$TARGET_PORT.\"
      exit 0
    fi

    echo \"Found existing listener(s) on port \$TARGET_PORT: \$PIDS\"
    print_listening_processes \"\$PIDS\"

    stop_systemd_service_if_needed || true

    PIDS=\"\$(get_listening_pids)\"
    if [[ -z \"\$PIDS\" ]]; then
      echo \"Port \$TARGET_PORT was released after stopping the service.\"
      exit 0
    fi

    kill \$PIDS 2>/dev/null || true

    wait_for_listener_exit 10 || true
    PIDS=\"\$(get_listening_pids)\"

    if [[ -n \"\${PIDS:-}\" ]]; then
      echo \"Listener(s) still present on port \$TARGET_PORT after SIGTERM; sending SIGKILL...\"
      print_listening_processes \"\$PIDS\"
      kill -9 \$PIDS 2>/dev/null || true
      sleep 1
    fi

    FINAL_PIDS=\"\$(get_listening_pids)\"
    if [[ -n \"\$FINAL_PIDS\" ]]; then
      echo \"Error: port \$TARGET_PORT is still in use by: \$FINAL_PIDS\" >&2
      print_listening_processes \"\$FINAL_PIDS\" >&2 || true
      if [[ -n \"\$SERVICE_UNIT\" ]] && command -v systemctl >/dev/null 2>&1 && systemd_unit_exists \"\$SERVICE_UNIT\"; then
        systemctl --user status \"\$SERVICE_UNIT\" --no-pager >&2 || true
      fi
      exit 1
    fi

    echo \"Port \$TARGET_PORT is clear.\"
  "
}

resolve_project_name_noninteractive() {
  local input_name="$1"
  local normalized_input
  local exact_match
  local -a partial_matches

  if [[ -z "$input_name" ]]; then
    return 1
  fi

  normalized_input="${(L)input_name}"

  exact_match="$(jq -r --arg q "$normalized_input" '
    ([.[] | select(
      (.name | ascii_downcase) == $q
      or (((.aliases // []) | map(ascii_downcase) | index($q)) != null)
    ) | .name][0]) // empty
  ' "$CONFIG_FILE")"
  if [[ -n "$exact_match" ]]; then
    echo "$exact_match"
    return 0
  fi

  partial_matches=("${(@f)$(project_match_list_candidates "$CONFIG_FILE" "$input_name")}")
  partial_matches=("${(@)partial_matches:#}")

  if (( ${#partial_matches[@]} == 1 )); then
    echo "$partial_matches[1]"
    return 0
  fi

  if (( ${#partial_matches[@]} > 1 )); then
    return 2
  fi

  return 1
}

project_query_looks_like_project() {
  local query="$1"
  local resolve_status

  resolve_project_name_noninteractive "$query" >/dev/null 2>&1
  resolve_status=$?
  [[ "$resolve_status" -eq 0 || "$resolve_status" -eq 2 ]]
}

project_query_has_wildcard() {
  local query="$1"

  case "$query" in
    (*'*'*|*'?'*|*'['*) return 0 ;;
    (*) return 1 ;;
  esac
}

expand_project_wildcard_query() {
  local query="$1"
  local normalized_query="${(L)query}"
  local project_line canonical candidate
  local -a project_names matched_projects

  while IFS= read -r project_line; do
    project_names=("${(ps:\t:)project_line}")
    canonical="${project_names[1]}"
    for candidate in "${project_names[@]}"; do
      if [[ "${(L)candidate}" == ${~normalized_query} ]]; then
        matched_projects+=("$canonical")
        break
      fi
    done
  done < <(jq -r '(.[] | ([.name] + (.aliases // [])) | @tsv)' "$CONFIG_FILE")

  matched_projects=("${(@)matched_projects:#}")
  typeset -U matched_projects
  if (( ${#matched_projects[@]} == 0 )); then
    return 1
  fi

  printf '%s\n' "${matched_projects[@]}"
}

expand_positional_project_wildcards() {
  local arg
  local -a expanded_args wildcard_matches

  for arg in "$@"; do
    wildcard_matches=()
    if project_query_has_wildcard "$arg" && wildcard_matches=("${(@f)$(expand_project_wildcard_query "$arg")}"); then
      expanded_args+=("${wildcard_matches[@]}")
    else
      expanded_args+=("$arg")
    fi
  done

  printf '%s\n' "${expanded_args[@]}"
}

notify_deploy_complete() {
  local project_name="$1"
  local host="$2"

  if [[ "$OSTYPE" == darwin* ]]; then
    if command -v say >/dev/null 2>&1; then
      afplay /System/Library/Sounds/Glass.aiff
    fi

    if command -v osascript >/dev/null 2>&1; then
      osascript - "$project_name" "$host" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set projectName to item 1 of argv
  set hostName to item 2 of argv
  display notification ("Deploy complete on " & hostName) with title "Node deploy" subtitle projectName
end run
APPLESCRIPT
    fi
  fi
}

tail_with_redeploy_controls() {
  local tail_script="$1"
  shift
  local -a tail_args=("$@")
  local -a tail_flags=("--tail")
  if [[ "$TAIL_ERRORS_ONLY" == "1" ]]; then
    tail_flags+=("--errors-only")
  fi

  local -a redeploy_cmd=("zsh" "$SCRIPT_PATH" "$PROJECT_NAME" "$HOST")
  redeploy_cmd+=("--quick")
  redeploy_cmd+=("${tail_flags[@]}")

  local -a full_redeploy_cmd=("zsh" "$SCRIPT_PATH" "$PROJECT_NAME" "$HOST")
  full_redeploy_cmd+=("${tail_flags[@]}")

  local -a bitwarden_sync_redeploy_cmd=("zsh" "$SCRIPT_PATH" "$PROJECT_NAME" "$HOST")
  bitwarden_sync_redeploy_cmd+=("--bw" "--force-bitwarden-sync")
  bitwarden_sync_redeploy_cmd+=("${tail_flags[@]}")

  echo "==> Starting log tail..."
  echo "    Controls: r = quick redeploy, f = full redeploy, b = full redeploy with Bitwarden credentials, Ctrl+C = stop."
  echo ""

  TAIL_SHOW_CONTROLS=0 zsh "$tail_script" "${tail_args[@]}" < /dev/null &
  local tail_pid=$!
  local key=""

  while kill -0 "$tail_pid" 2>/dev/null; do
    if read -r -k 1 -s -t 0.2 key; then
      case "$key" in
        r|R)
          echo ""
          echo "==> Quick redeploy requested. Restarting deployment..."
          kill "$tail_pid" 2>/dev/null || true
          wait "$tail_pid" 2>/dev/null || true
          exec "${redeploy_cmd[@]}"
          ;;
        f|F)
          echo ""
          echo "==> Full redeploy requested. Restarting deployment..."
          kill "$tail_pid" 2>/dev/null || true
          wait "$tail_pid" 2>/dev/null || true
          exec "${full_redeploy_cmd[@]}"
          ;;
        b|B)
          echo ""
          echo "==> Full redeploy with Bitwarden credentials requested. Restarting deployment..."
          kill "$tail_pid" 2>/dev/null || true
          wait "$tail_pid" 2>/dev/null || true
          exec "${bitwarden_sync_redeploy_cmd[@]}"
          ;;
      esac
    fi
  done

  if wait "$tail_pid"; then
    return 0
  else
    local tail_status="$?"
    echo "Error: log tail exited with status ${tail_status}" >&2
    return "$tail_status"
  fi
}

run_remote_pnpm_install() {
  local -a install_args=("$@")

  ssh "$HOST" "bash -s" -- "$REMOTE_DIR" "${install_args[@]}" <<'REMOTE_SCRIPT'
set -euo pipefail

export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'

remote_dir="$1"
shift

case "$remote_dir" in
  "~")
    remote_dir="$HOME"
    ;;
  "~/"*)
    remote_dir="$HOME/${remote_dir#~/}"
    ;;
esac

cd "$remote_dir"

lock_key="$(printf '%s' "$PWD" | cksum | awk '{print $1}')"
lock_dir="${TMPDIR:-/tmp}/node_project_pnpm_${USER:-user}_${lock_key}.lock"
lock_timeout_seconds="${DEPLOY_PNPM_LOCK_TIMEOUT_SECONDS:-300}"
lock_start="$(date +%s)"
lock_acquired=0
tmp_output=""

cleanup() {
  if [[ -n "$tmp_output" ]]; then
    rm -f "$tmp_output"
  fi
  if [[ "$lock_acquired" == "1" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

while ! mkdir "$lock_dir" 2>/dev/null; do
  now="$(date +%s)"
  if (( now - lock_start >= lock_timeout_seconds )); then
    echo "Timed out waiting for pnpm install lock: $lock_dir" >&2
    exit 1
  fi
  echo "Waiting for another pnpm install in $PWD to finish..."
  sleep 2
done
lock_acquired=1

tmp_output="$(mktemp "${TMPDIR:-/tmp}/node_project_pnpm.XXXXXX" 2>/dev/null || mktemp -t node_project_pnpm)"
if pnpm install "$@" 2>&1 | tee "$tmp_output"; then
  exit 0
fi
install_status="${PIPESTATUS[0]}"

if grep -Eq "ENOENT.*node_modules/\\.pnpm/node_modules|node_modules/\\.pnpm/node_modules.*ENOENT" "$tmp_output"; then
  echo "pnpm hit a hoisted node_modules ENOENT; clearing hoisted links and retrying once..." >&2
  rm -rf node_modules/.pnpm/node_modules
  pnpm install "$@"
else
  exit "$install_status"
fi
REMOTE_SCRIPT
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

disable_remote_deployment() {
  local host="$1"
  local remote_dir="$2"
  shift 2
  local -a service_labels=("$@")

  ssh -o ConnectTimeout=10 "$host" "bash -s" -- "$remote_dir" "${service_labels[@]}" <<'REMOTE_DISABLE_SCRIPT'
    set -euo pipefail
    REMOTE_DIR="$1"
    shift
    SERVICE_LABELS=("$@")

    case "$REMOTE_DIR" in
      "~")
        REMOTE_DIR_EXPANDED="$HOME"
        ;;
      "~/"*)
        REMOTE_DIR_EXPANDED="$HOME/${REMOTE_DIR#~/}"
        ;;
      *)
        REMOTE_DIR_EXPANDED="$REMOTE_DIR"
        ;;
    esac

    stop_remaining_node_processes() {
      if ! command -v ps >/dev/null 2>&1; then
        echo 'Warning: ps not available; skipping process fallback check.' >&2
        return 0
      fi

      local pids remaining
      pids="$(ps -eo pid=,comm=,args= | awk -v dir="$REMOTE_DIR_EXPANDED/" '$2 == "node" && index($0, dir) { print $1 }' || true)"
      if [[ -z "$pids" ]]; then
        echo "No remaining Node processes found under $REMOTE_DIR_EXPANDED."
        return 0
      fi

      echo "Found remaining Node process IDs under $REMOTE_DIR_EXPANDED:"
      echo "$pids"
      kill $pids 2>/dev/null || true
      sleep 2

      remaining="$(ps -eo pid=,comm=,args= | awk -v dir="$REMOTE_DIR_EXPANDED/" '$2 == "node" && index($0, dir) { print $1 }' || true)"
      if [[ -n "$remaining" ]]; then
        echo 'Processes still running after SIGTERM; sending SIGKILL...'
        echo "$remaining"
        kill -9 $remaining 2>/dev/null || true
        sleep 1
      fi

      remaining="$(ps -eo pid=,comm=,args= | awk -v dir="$REMOTE_DIR_EXPANDED/" '$2 == "node" && index($0, dir) { print $1 }' || true)"
      if [[ -n "$remaining" ]]; then
        echo 'Error: matching Node processes are still running:' >&2
        echo "$remaining" >&2
        return 1
      fi

      echo "No remaining Node processes found under $REMOTE_DIR_EXPANDED."
    }

    if command -v launchctl >/dev/null 2>&1; then
      UID_NUM="$(id -u)"
      echo 'Detected launchd (macOS).'

      for SERVICE_LABEL in "${SERVICE_LABELS[@]}"; do
        [[ -n "$SERVICE_LABEL" ]] || continue
        echo "Disabling and stopping launchd service: $SERVICE_LABEL"

        domain_seen=0
        for DOMAIN in "gui/$UID_NUM" "user/$UID_NUM"; do
          if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
            continue
          fi
          domain_seen=1
          launchctl disable "$DOMAIN/$SERVICE_LABEL" || true
          launchctl bootout "$DOMAIN/$SERVICE_LABEL" 2>/dev/null || true
        done

        if [[ "$domain_seen" -eq 0 ]]; then
          echo "Warning: no usable launchd domain found while handling $SERVICE_LABEL" >&2
        fi

        still_loaded=0
        for DOMAIN in "gui/$UID_NUM" "user/$UID_NUM"; do
          if launchctl print "$DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1; then
            echo "Service still loaded in $DOMAIN: $SERVICE_LABEL" >&2
            still_loaded=1
          fi
        done

        if [[ "$still_loaded" -eq 1 ]]; then
          exit 1
        fi
      done

      echo 'Deployment services disabled via launchd.'
      stop_remaining_node_processes
    elif command -v systemctl >/dev/null 2>&1; then
      echo 'Detected systemd (Linux).'
      systemctl --user daemon-reload || true

      for SERVICE_LABEL in "${SERVICE_LABELS[@]}"; do
        [[ -n "$SERVICE_LABEL" ]] || continue
        SERVICE_UNIT="${SERVICE_LABEL}.service"
        echo "Disabling and stopping systemd service: $SERVICE_UNIT"
        systemctl --user disable "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl --user stop --no-block "$SERVICE_UNIT" >/dev/null 2>&1 || true

        for _ in $(seq 1 20); do
          state="$(systemctl --user is-active "$SERVICE_UNIT" 2>/dev/null || true)"
          if [[ "$state" != 'active' && "$state" != 'activating' ]]; then
            break
          fi
          sleep 1
        done

        final_state="$(systemctl --user is-active "$SERVICE_UNIT" 2>/dev/null || true)"
        if [[ "$final_state" == 'active' || "$final_state" == 'activating' ]]; then
          echo "Service state is still '$final_state'; sending SIGTERM to $SERVICE_UNIT..."
          systemctl --user kill --kill-who=all --signal=SIGTERM "$SERVICE_UNIT" >/dev/null 2>&1 || true
          sleep 2
          final_state="$(systemctl --user is-active "$SERVICE_UNIT" 2>/dev/null || true)"
        fi

        if [[ "$final_state" == 'active' || "$final_state" == 'activating' ]]; then
          echo "Service state is still '$final_state'; sending SIGKILL to $SERVICE_UNIT..."
          systemctl --user kill --kill-who=all --signal=SIGKILL "$SERVICE_UNIT" >/dev/null 2>&1 || true
          systemctl --user stop --no-block "$SERVICE_UNIT" >/dev/null 2>&1 || true
          sleep 1
          final_state="$(systemctl --user is-active "$SERVICE_UNIT" 2>/dev/null || true)"
        fi

        enabled_state="$(systemctl --user is-enabled "$SERVICE_UNIT" 2>/dev/null || true)"
        echo "Final state for $SERVICE_UNIT: active=${final_state:-unknown}, enabled=${enabled_state:-unknown}"

        if [[ "$final_state" == 'active' || "$final_state" == 'activating' ]]; then
          systemctl --user status "$SERVICE_UNIT" --no-pager || true
          exit 1
        fi
      done

      echo 'Deployment services disabled via systemd.'
      stop_remaining_node_processes
    else
      echo 'Error: Neither launchctl nor systemctl is available on this host.' >&2
      exit 1
    fi
REMOTE_DISABLE_SCRIPT
}

prefix_parallel_output() {
  local project_name="$1"
  local line

  while IFS= read -r line; do
    printf '[%s] %s\n' "$project_name" "$line"
  done
}

resolve_project_args() {
  local -a project_queries=("$@")
  local project_query resolved_project resolve_status

  if (( ${#project_queries[@]} < 2 )); then
    return 1
  fi

  for project_query in "${project_queries[@]}"; do
    if resolved_project="$(resolve_project_name_noninteractive "$project_query")"; then
      printf '%s\n' "$resolved_project"
    else
      return "$?"
    fi
  done
}

tail_parallel_deploy_logs() {
  local host="$1"
  shift
  local -a project_names=("$@")
  local -a tail_pids=()
  local -a tail_args=()
  local project_name pid tail_status failed_count
  local tail_script="$SCRIPT_DIR/tail_node_project.zsh"

  if [[ ! -f "$tail_script" ]]; then
    echo "Error: Tail script not found: $tail_script" >&2
    exit 1
  fi

  echo "==> Starting parallel log tails..."
  echo "    Ctrl+C = stop all tails."
  echo ""

  cleanup_parallel_tails() {
    local tail_pid
    for tail_pid in "${tail_pids[@]}"; do
      kill "$tail_pid" >/dev/null 2>&1 || true
    done
    for tail_pid in "${tail_pids[@]}"; do
      wait "$tail_pid" 2>/dev/null || true
    done
  }
  trap cleanup_parallel_tails INT TERM EXIT

  for project_name in "${project_names[@]}"; do
    tail_args=("$project_name" "$host")
    if [[ "$TAIL_ERRORS_ONLY" == "1" ]]; then
      tail_args+=("--errors-only")
    fi

    (
      TAIL_SHOW_CONTROLS=0 zsh "$tail_script" "${tail_args[@]}" < /dev/null
    ) > >(prefix_parallel_output "$project_name") 2> >(prefix_parallel_output "$project_name" >&2) &
    pid="$!"
    tail_pids+=("$pid")
  done

  failed_count=0
  for pid in "${tail_pids[@]}"; do
    if wait "$pid"; then
      :
    else
      tail_status="$?"
      if [[ "$tail_status" -ne 130 && "$tail_status" -ne 143 ]]; then
        failed_count=$((failed_count + 1))
      fi
    fi
  done

  trap - INT TERM EXIT
  if (( failed_count > 0 )); then
    echo "Error: $failed_count parallel log tail(s) exited with errors." >&2
    exit 1
  fi
}

run_parallel_deployments() {
  local host="$1"
  shift
  local -a project_names=("$@")
  local -a child_switch_args=()
  local -a child_pids=()
  local -a child_projects=()
  local project_name pid deploy_status failed_count

  if [[ "$QUICK_MODE" == "1" ]]; then
    child_switch_args+=("--quick")
  fi
  if [[ "$DISABLE_MODE" == "1" ]]; then
    child_switch_args+=("--disable")
  fi
  if [[ "$BW_FORCE_SYNC" == "1" ]]; then
    child_switch_args+=("--force-bitwarden-sync")
  elif [[ "$BW_ENV_SYNC" == "1" ]]; then
    child_switch_args+=("--bw")
  fi

  echo "==> Deploying ${#project_names[@]} projects in parallel to $host:"
  printf '    - %s\n' "${project_names[@]}"
  echo ""

  for project_name in "${project_names[@]}"; do
    (
      "$SCRIPT_PATH" "$project_name" "$host" "${child_switch_args[@]}"
    ) > >(prefix_parallel_output "$project_name") 2> >(prefix_parallel_output "$project_name" >&2) &
    pid="$!"
    child_pids+=("$pid")
    child_projects+=("$project_name")
  done

  failed_count=0
  for ((idx = 1; idx <= ${#child_pids[@]}; idx++)); do
    pid="${child_pids[$idx]}"
    project_name="${child_projects[$idx]}"
    if wait "$pid"; then
      echo "==> Parallel deploy finished: $project_name"
    else
      deploy_status="$?"
      echo "❌ Parallel deploy failed for $project_name (exit $deploy_status)" >&2
      failed_count=$((failed_count + 1))
    fi
  done

  if (( failed_count > 0 )); then
    echo "❌ $failed_count parallel deploy(s) failed." >&2
    exit 1
  fi

  echo "✅ Parallel deploy complete."
  if [[ "$TAIL_MODE" == "1" ]]; then
    tail_parallel_deploy_logs "$host" "${project_names[@]}"
  fi
  exit 0
}

# Parse switches before positional args.
typeset -a POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    disable|--disable|--disable-deployment|-d)
      DISABLE_MODE=1
      ;;
    quick|--quick|-q)
      QUICK_MODE=1
      ;;
    bw|--bw|--bitwarden)
      BW_ENV_SYNC=1
      ;;
    --force-bitwarden-sync|--force-bw-sync|-b)
      BW_ENV_SYNC=1
      BW_FORCE_SYNC=1
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
if [[ $# -gt 0 ]]; then
  POSITIONAL_ARGS=("${(@f)$(expand_positional_project_wildcards "$@")}")
  set -- "${POSITIONAL_ARGS[@]}"
fi

if [[ "$TAIL_ERRORS_ONLY" == "1" && "$TAIL_MODE" == "0" ]]; then
  TAIL_MODE=1
fi

if [[ $# -ge 3 ]]; then
  # Multi-project mode supports both PROJECT PROJECT... HOST and HOST PROJECT PROJECT...
  # forms. Each project must resolve independently so existing multi-word single-project
  # queries continue to flow through the single-project parser below.
  HOST_FIRST_CANDIDATE="${argv[1]}"
  HOST_LAST_CANDIDATE="${argv[$#]}"
  HOST_FIRST_PROJECTS=("${(@)argv[2,$#]}")
  HOST_LAST_PROJECTS=("${(@)argv[1,$(( $# - 1 ))]}")

  HOST_FIRST_MULTI_STATUS=1
  HOST_LAST_MULTI_STATUS=1
  HOST_FIRST_PROJECT_NAMES=()
  HOST_LAST_PROJECT_NAMES=()

  if HOST_FIRST_PROJECT_NAMES=("${(@f)$(resolve_project_args "${HOST_FIRST_PROJECTS[@]}")}"); then
    HOST_FIRST_MULTI_STATUS=0
  else
    HOST_FIRST_MULTI_STATUS=$?
  fi

  if HOST_LAST_PROJECT_NAMES=("${(@f)$(resolve_project_args "${HOST_LAST_PROJECTS[@]}")}"); then
    HOST_LAST_MULTI_STATUS=0
  else
    HOST_LAST_MULTI_STATUS=$?
  fi

  if [[ "$HOST_FIRST_MULTI_STATUS" -eq 0 && "$HOST_LAST_MULTI_STATUS" -ne 0 ]]; then
    run_parallel_deployments "$HOST_FIRST_CANDIDATE" "${HOST_FIRST_PROJECT_NAMES[@]}"
  elif [[ "$HOST_LAST_MULTI_STATUS" -eq 0 && "$HOST_FIRST_MULTI_STATUS" -ne 0 ]]; then
    run_parallel_deployments "$HOST_LAST_CANDIDATE" "${HOST_LAST_PROJECT_NAMES[@]}"
  elif [[ "$HOST_FIRST_MULTI_STATUS" -eq 0 && "$HOST_LAST_MULTI_STATUS" -eq 0 ]]; then
    if ! project_query_looks_like_project "$HOST_FIRST_CANDIDATE" && project_query_looks_like_project "$HOST_LAST_CANDIDATE"; then
      run_parallel_deployments "$HOST_FIRST_CANDIDATE" "${HOST_FIRST_PROJECT_NAMES[@]}"
    elif project_query_looks_like_project "$HOST_FIRST_CANDIDATE" && ! project_query_looks_like_project "$HOST_LAST_CANDIDATE"; then
      run_parallel_deployments "$HOST_LAST_CANDIDATE" "${HOST_LAST_PROJECT_NAMES[@]}"
    else
      echo "Error: Could not determine which positional argument is the host for parallel deploy." >&2
      echo "Tried both '$HOST_FIRST_CANDIDATE' and '$HOST_LAST_CANDIDATE' as the deployment target." >&2
      exit 1
    fi
  fi
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
elif [[ $# -ge 2 ]]; then
  # Support both PROJECT... HOST and HOST PROJECT... forms.
  HOST_FIRST_CANDIDATE="${argv[1]}"
  HOST_FIRST_QUERY="${(j: :)argv[2,$#]}"
  HOST_LAST_QUERY="${(j: :)argv[1,$(( $# - 1 ))]}"
  HOST_LAST_CANDIDATE="${argv[$#]}"

  HOST_FIRST_STATUS=1
  HOST_LAST_STATUS=1
  HOST_FIRST_PROJECT=""
  HOST_LAST_PROJECT=""

  if HOST_FIRST_PROJECT="$(resolve_project_name_noninteractive "$HOST_FIRST_QUERY")"; then
    HOST_FIRST_STATUS=0
  else
    HOST_FIRST_STATUS=$?
  fi

  if HOST_LAST_PROJECT="$(resolve_project_name_noninteractive "$HOST_LAST_QUERY")"; then
    HOST_LAST_STATUS=0
  else
    HOST_LAST_STATUS=$?
  fi

  if [[ "$HOST_FIRST_STATUS" -eq 0 && "$HOST_LAST_STATUS" -ne 0 ]]; then
    PROJECT_NAME="$HOST_FIRST_QUERY"
    HOST="$HOST_FIRST_CANDIDATE"
  elif [[ "$HOST_LAST_STATUS" -eq 0 && "$HOST_FIRST_STATUS" -ne 0 ]]; then
    PROJECT_NAME="$HOST_LAST_QUERY"
    HOST="$HOST_LAST_CANDIDATE"
  elif [[ "$HOST_FIRST_STATUS" -eq 2 && "$HOST_LAST_STATUS" -eq 1 ]]; then
    PROJECT_NAME="$HOST_FIRST_QUERY"
    HOST="$HOST_FIRST_CANDIDATE"
  elif [[ "$HOST_LAST_STATUS" -eq 2 && "$HOST_FIRST_STATUS" -eq 1 ]]; then
    PROJECT_NAME="$HOST_LAST_QUERY"
    HOST="$HOST_LAST_CANDIDATE"
  elif [[ "$HOST_FIRST_STATUS" -eq 0 && "$HOST_LAST_STATUS" -eq 0 ]]; then
    if ! project_query_looks_like_project "$HOST_FIRST_CANDIDATE" && project_query_looks_like_project "$HOST_LAST_CANDIDATE"; then
      PROJECT_NAME="$HOST_FIRST_QUERY"
      HOST="$HOST_FIRST_CANDIDATE"
    elif project_query_looks_like_project "$HOST_FIRST_CANDIDATE" && ! project_query_looks_like_project "$HOST_LAST_CANDIDATE"; then
      PROJECT_NAME="$HOST_LAST_QUERY"
      HOST="$HOST_LAST_CANDIDATE"
    else
      echo "Error: Could not determine which positional argument is the host." >&2
      echo "Tried both '$HOST_FIRST_CANDIDATE' and '$HOST_LAST_CANDIDATE' as the deployment target." >&2
      echo "Use a less ambiguous project query or keep the existing PROJECT... HOST order." >&2
      exit 1
    fi
  elif [[ "$HOST_FIRST_STATUS" -eq 2 && "$HOST_LAST_STATUS" -eq 2 ]]; then
    echo "Error: Project query is ambiguous in both HOST PROJECT... and PROJECT... HOST forms." >&2
    echo "Use a more specific project query." >&2
    exit 1
  else
    # Backward-compatible fallback: treat the final positional argument as the host.
    PROJECT_NAME="$HOST_LAST_QUERY"
    HOST="$HOST_LAST_CANDIDATE"
  fi
else
  echo "Usage: $0 [PROJECT_QUERY... HOST] [--quick|-q|quick] [--disable|-d|disable] [bw|--bw|--bitwarden] [-b|--force-bitwarden-sync] [--tail|-t|tail] [--errors-only|-e|errors-only]" >&2
  echo "  If no parameters provided, interactive mode will be used" >&2
  echo "  Manual mode supports either: [PROJECT_QUERY... HOST] or [HOST PROJECT_QUERY...]" >&2
  echo "  Example: $0 top web ocl --quick" >&2
  echo "  Example: $0 ocl --quick top web" >&2
  echo "  Parallel example: $0 kidsplorers kidsplorers-web ocl --quick" >&2
  echo "  Wildcard example: $0 sky 'kid*' --quick" >&2
  echo "  --quick/-q/quick: sync files and restart service only (skip deps, Bitwarden, healthcheck, Grafana)" >&2
  echo "  --disable/-d/disable: stop and disable the deployment services on the target host, then exit" >&2
  echo "  bw/--bw/--bitwarden: sync and apply Bitwarden-managed environment credentials" >&2
  echo "  -b/--force-bitwarden-sync/--force-bw-sync: sync/apply Bitwarden credentials and force a vault refresh first" >&2
  echo "  --tail/-t/tail: tail remote stdout/stderr log files after deploy completes" >&2
  echo "  --errors-only/-e/errors-only: when tailing, only follow remote stderr log" >&2
  echo "  --tail-errors/tail-errors: shorthand for --tail --errors-only" >&2
  echo "" >&2
  list_projects >&2
  exit 1
fi

if ! PROJECT_NAME="$(project_match_resolve_name "$CONFIG_FILE" "$PROJECT_NAME")"; then
  exit 1
fi

# Get project configuration from config file
LOCAL_DIR=$(get_project_path "$PROJECT_NAME")
METRICS_PORT=$(get_project_metrics_port "$PROJECT_NAME")
STARTUP_PORT=$(get_project_startup_port "$PROJECT_NAME")
BUILD_COMMAND=$(get_project_build_command "$PROJECT_NAME")
SERVICE_LABEL=$(get_project_service_label "$PROJECT_NAME")
SERVICE_DESCRIPTION=$(get_project_service_description "$PROJECT_NAME")
LEGACY_SERVICE_LABELS=("${(@f)$(get_project_legacy_service_labels "$PROJECT_NAME")}")
SERVICES_JSON="$(get_project_services_json "$PROJECT_NAME")"
CONFIGURED_BW_REMOTE_ENV_FILE_NAME="$(get_project_bw_remote_env_file_name "$PROJECT_NAME")"
if [[ -n "$CONFIGURED_BW_REMOTE_ENV_FILE_NAME" ]]; then
  BW_REMOTE_ENV_FILE_NAME="$CONFIGURED_BW_REMOTE_ENV_FILE_NAME"
fi

if [[ -z "$SERVICE_LABEL" ]]; then
  SERVICE_LABEL="com.${PROJECT_NAME}.api"
fi

if [[ -z "$SERVICE_DESCRIPTION" ]]; then
  SERVICE_DESCRIPTION="${PROJECT_NAME} API Service"
fi

LEGACY_SERVICE_LABELS=("${(@)LEGACY_SERVICE_LABELS:#}")
LEGACY_SERVICE_LABELS=("${(@)LEGACY_SERVICE_LABELS:#$SERVICE_LABEL}")
typeset -U LEGACY_SERVICE_LABELS

if [[ -n "$SERVICES_JSON" && "$SERVICES_JSON" != "null" ]]; then
  SERVICE_SPECS=("${(@f)$(printf '%s\n' "$SERVICES_JSON" | jq -r '
    .[] | [
      .name,
      .service_label,
      .service_description,
      (if (.entry_file // "") == "" then "__AUTO__" else .entry_file end),
      (if (.startup_port // "") == "" then "__NONE__" else (.startup_port | tostring) end),
      (if (.metrics_port // "") == "" then "__NONE__" else (.metrics_port | tostring) end),
      .log_file,
      .error_log_file
    ] | @tsv
  ')}")
else
  SERVICE_SPECS=()
fi

SERVICE_NAMES=()
SERVICE_LABELS=()
SERVICE_DESCRIPTIONS=()
SERVICE_ENTRY_FILES=()
SERVICE_STARTUP_PORTS=()
SERVICE_METRICS_PORTS=()
SERVICE_LOG_FILES=()
SERVICE_ERROR_LOG_FILES=()

for service_spec in "${SERVICE_SPECS[@]}"; do
  service_fields=("${(ps:\t:)service_spec}")
  SERVICE_NAMES+=("${service_fields[1]}")
  SERVICE_LABELS+=("${service_fields[2]}")
  SERVICE_DESCRIPTIONS+=("${service_fields[3]}")
  SERVICE_ENTRY_FILES+=("${service_fields[4]}")
  SERVICE_STARTUP_PORTS+=("${service_fields[5]}")
  SERVICE_METRICS_PORTS+=("${service_fields[6]}")
  SERVICE_LOG_FILES+=("${service_fields[7]}")
  SERVICE_ERROR_LOG_FILES+=("${service_fields[8]}")
done

if [[ ${#SERVICE_LABELS[@]} -eq 0 ]]; then
  SERVICE_NAMES=("api")
  SERVICE_LABELS=("$SERVICE_LABEL")
  SERVICE_DESCRIPTIONS=("$SERVICE_DESCRIPTION")
  SERVICE_ENTRY_FILES=("__AUTO__")
  SERVICE_STARTUP_PORTS=("${STARTUP_PORT:-__NONE__}")
  SERVICE_METRICS_PORTS=("${METRICS_PORT:-__NONE__}")
  SERVICE_LOG_FILES=("${PROJECT_NAME}.log")
  SERVICE_ERROR_LOG_FILES=("${PROJECT_NAME}.error.log")
fi

SERVICE_NAMES_SSH="${(j: :)SERVICE_NAMES}"
SERVICE_LABELS_SSH="${(j: :)SERVICE_LABELS}"
SERVICE_ENTRY_FILES_SSH="${(j: :)SERVICE_ENTRY_FILES}"
SERVICE_STARTUP_PORTS_SSH="${(j: :)SERVICE_STARTUP_PORTS}"
SERVICE_METRICS_PORTS_SSH="${(j: :)SERVICE_METRICS_PORTS}"
SERVICE_LOG_FILES_SSH="${(j: :)SERVICE_LOG_FILES}"
SERVICE_ERROR_LOG_FILES_SSH="${(j: :)SERVICE_ERROR_LOG_FILES}"

if [[ -z "$LOCAL_DIR" || "$LOCAL_DIR" == "null" ]]; then
  echo "Error: Project '$PROJECT_NAME' not found in config file" >&2
  echo "" >&2
  echo "To add a new project, update: $CONFIG_FILE" >&2
  echo "Add a JSON object with these fields:" >&2
  echo "  - name: canonical deploy name (used by this script and remote dir/service label)" >&2
  echo "  - aliases: optional array of alternate names that map to this project" >&2
  echo "  - path: absolute local path to the project directory" >&2
  echo "  - start_command: startup command (for documentation; script auto-detects server.js/server.mjs/index.js/index.mjs)" >&2
  echo "  - build_command: optional build command to run on the remote host before restart" >&2
  echo "  - service_label: optional service identifier for launchd/systemd" >&2
  echo "  - service_description: optional service description for launchd/systemd" >&2
  echo "  - legacy_service_labels: optional array of old service labels to remove during full deploy" >&2
  echo "  - startup_port: app HTTP port used for post-deploy /healthcheck (optional; defaults to metrics_port)" >&2
  echo "  - metrics_port: app metrics port for observability integration" >&2
  echo "" >&2
  list_projects >&2
  exit 1
fi

PROJECT_AND_ALIAS_NAMES=("${(@f)$(get_project_and_alias_names "$PROJECT_NAME")}")
if [[ ${#PROJECT_AND_ALIAS_NAMES[@]} -eq 0 ]]; then
  PROJECT_AND_ALIAS_NAMES=("$PROJECT_NAME")
fi
typeset -U PROJECT_AND_ALIAS_NAMES

DISABLE_SERVICE_LABELS=()
for name in "${PROJECT_AND_ALIAS_NAMES[@]}"; do
  DISABLE_SERVICE_LABELS+=("com.${name}.api")
done
DISABLE_SERVICE_LABELS+=("${SERVICE_LABELS[@]}")
DISABLE_SERVICE_LABELS+=("${LEGACY_SERVICE_LABELS[@]}")
DISABLE_SERVICE_LABELS=("${(@)DISABLE_SERVICE_LABELS:#}")
typeset -U DISABLE_SERVICE_LABELS

# Expand tilde in path if present
LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"
PROJECT_IS_VITE=0
PROJECT_HAS_PREPARE_ASSETS=0
PROJECT_BUILD_RUNS_PREPARE_ASSETS=0

CONFIGURED_REMOTE_DIR="$(get_project_remote_dir "$PROJECT_NAME")"
if [[ -n "$CONFIGURED_REMOTE_DIR" ]]; then
  REMOTE_DIR="$CONFIGURED_REMOTE_DIR"
else
  REMOTE_DIR="~/dev/${PROJECT_NAME}"
fi
LEGACY_SERVICE_LABELS_SSH="${(j: :)${(q)LEGACY_SERVICE_LABELS}}"

echo "==> Deploying project: $PROJECT_NAME"
echo "    Local path: $LOCAL_DIR"
echo "    Remote host: $HOST"
echo "    Remote path: $REMOTE_DIR"
echo "    Service label: $SERVICE_LABEL"
echo "    Service description: $SERVICE_DESCRIPTION"
if [[ "$DISABLE_MODE" == "1" ]]; then
  echo "    Services to disable:"
  printf '      - %s\n' "${DISABLE_SERVICE_LABELS[@]}"
elif [[ ${#SERVICE_LABELS[@]} -gt 1 ]]; then
  echo "    Managed services:"
  for ((idx = 1; idx <= ${#SERVICE_LABELS[@]}; idx++)); do
    echo "      - ${SERVICE_LABELS[$idx]} (${SERVICE_NAMES[$idx]})"
  done
fi
if [[ ${#LEGACY_SERVICE_LABELS[@]} -gt 0 ]]; then
  echo "    Legacy service labels to remove:"
  printf '      - %s\n' "${LEGACY_SERVICE_LABELS[@]}"
fi
echo "    Deploy mode: $([[ "$DISABLE_MODE" == "1" ]] && echo "disable" || ([[ "$QUICK_MODE" == "1" ]] && echo "quick" || echo "full"))"
echo "    Tail logs after deploy: $([[ "$TAIL_MODE" == "1" ]] && echo "yes" || echo "no")"
if [[ "$TAIL_MODE" == "1" ]]; then
  echo "    Tail mode: $([[ "$TAIL_ERRORS_ONLY" == "1" ]] && echo "errors only" || echo "stdout + stderr")"
fi
echo ""

if [[ "$DISABLE_MODE" == "1" ]]; then
  echo "==> Disabling deployment services on $HOST..."
  disable_remote_deployment "$HOST" "$REMOTE_DIR" "${DISABLE_SERVICE_LABELS[@]}"
  echo ""
  echo "✅ Deployment disabled for $PROJECT_NAME on $HOST."
  exit 0
fi

if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "Local dir not found: $LOCAL_DIR" >&2
  exit 1
fi

if project_uses_vite "$LOCAL_DIR"; then
  PROJECT_IS_VITE=1
fi

PROJECT_IS_PNPM=0
if [[ -f "$LOCAL_DIR/pnpm-workspace.yaml" || -f "$LOCAL_DIR/pnpm-lock.yaml" ]]; then
  PROJECT_IS_PNPM=1
fi

if project_package_has_script "$LOCAL_DIR" "prepare-assets"; then
  PROJECT_HAS_PREPARE_ASSETS=1
fi

if project_build_runs_prepare_assets "$LOCAL_DIR"; then
  PROJECT_BUILD_RUNS_PREPARE_ASSETS=1
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
  --exclude '.env' \
  --include '.env.local' \
  --exclude '.static-config*.env.sh' \
  --exclude "$BW_REMOTE_ENV_FILE_NAME" \
  --exclude '.bw-secrets*.env.sh' \
  --exclude '.start-with-bw-env.sh' \
  --exclude '.start-with-bw-env-*.sh' \
  --exclude '.claude' \
  --exclude 'certs' \
  --exclude 'coverage' \
  --exclude 'dist' \
  --exclude '*_local_only*' \
  --exclude '.next' \
  --exclude '.turbo' \
  --exclude '*.local' \
  "$LOCAL_DIR/" \
  "${HOST}:${REMOTE_DIR}/"

echo "==> Ensuring app certs symlink exists..."
ssh "$HOST" "
  set -euo pipefail
  REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)
  APP_CERTS_DIR=\"\$REMOTE_DIR_EXPANDED/certs\"
  SHARED_CERTS_DIR=\"\$HOME/.certs\"

  if [[ ! -e \"\$APP_CERTS_DIR\" && ! -L \"\$APP_CERTS_DIR\" ]]; then
    ln -s \"\$SHARED_CERTS_DIR\" \"\$APP_CERTS_DIR\"
    echo \"   Linked \$APP_CERTS_DIR -> \$SHARED_CERTS_DIR\"
  fi
"

STATIC_ENV_CONTENT="$(get_project_static_env "$PROJECT_NAME")"
if [[ -n "$STATIC_ENV_CONTENT" ]]; then
  echo "==> Writing static (non-sensitive) environment config..."
  STATIC_CONFIG_FILE_NAME=".static-config-${PROJECT_NAME}.env.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$STATIC_ENV_CONTENT" | \
    ssh "$HOST" "cat > ${REMOTE_DIR}/${STATIC_CONFIG_FILE_NAME}.tmp && mv ${REMOTE_DIR}/${STATIC_CONFIG_FILE_NAME}.tmp ${REMOTE_DIR}/${STATIC_CONFIG_FILE_NAME} && chmod 600 ${REMOTE_DIR}/${STATIC_CONFIG_FILE_NAME}"
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping standard dependency install."
  if [[ "$PROJECT_IS_VITE" == "1" && -n "$BUILD_COMMAND" ]]; then
    echo "==> Quick mode: rebuilding Vite assets on server..."
    ssh "$HOST" "
      set -e
      export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
      cd $REMOTE_DIR

      if ! npm ls vite >/dev/null 2>&1; then
        echo 'Installing Vite build dependencies for quick deploy...'
        if [[ -f package-lock.json ]]; then
          npm ci
        else
          npm install
        fi
      fi

      if [[ '$PROJECT_HAS_PREPARE_ASSETS' == '1' && '$PROJECT_BUILD_RUNS_PREPARE_ASSETS' != '1' ]]; then
        npm run prepare-assets
      fi

      $BUILD_COMMAND
    "
  fi
else
  echo "==> Installing deps on server..."
  if [[ "$PROJECT_IS_PNPM" == "1" ]]; then
    if [[ -n "$BUILD_COMMAND" ]]; then
      run_remote_pnpm_install
    else
      run_remote_pnpm_install --prod
    fi
  elif [[ -n "$BUILD_COMMAND" ]]; then
    ssh "$HOST" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'; \
      cd $REMOTE_DIR && \
      if [[ -f package-lock.json ]]; then
        npm ci
      else
        npm install
      fi"
  else
    ssh "$HOST" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'; \
      cd $REMOTE_DIR && \
      if [[ -f package-lock.json ]]; then
        npm ci --omit=dev
      else
        npm install --omit=dev
      fi"
  fi

  if [[ -n "$BUILD_COMMAND" ]]; then
    echo "==> Running build command on server..."
    ssh "$HOST" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'; \
      cd $REMOTE_DIR && \
      $BUILD_COMMAND"

    if [[ "$PROJECT_IS_PNPM" != "1" ]]; then
      echo "==> Pruning dev dependencies on server..."
      ssh "$HOST" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'; \
        cd $REMOTE_DIR && \
        npm prune --omit=dev"
    fi
  fi
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping Bitwarden env sync."
elif [[ "$BW_ENV_SYNC" == "1" ]]; then
  echo "==> Syncing Bitwarden-managed environment variables..."
  ensure_bw_session
  refresh_bw_vault_data_if_needed

  bw_items_json="$(run_bw_json_with_session list items --folderid "$BW_FOLDER_ID")"
  project_aliases_json="$(jq -c --arg name "$PROJECT_NAME" '
    [.[] | select(.name == $name) | .aliases // [] | .[]] | map(ascii_downcase)
  ' "$CONFIG_FILE")"
  matching_items_jsonl="$(
    printf '%s\n' "$bw_items_json" | jq -r \
      --arg project "$PROJECT_NAME" \
      --arg apps_field "$BW_APPS_FIELD_NAME" \
      --argjson aliases "$project_aliases_json" '
      def norm: ascii_downcase | gsub("^\\s+|\\s+$"; "");
      ($project | norm) as $project_norm
      | ([$project_norm] + $aliases) as $project_names
      | .[]?
      | . as $item
      | ((.fields // [] | map(select((.name // "" | norm) == ($apps_field | norm))) | .[0].value) // "") as $apps
      | ($apps | split("[,;\\s]+"; "x") | map(norm) | map(select(length > 0))) as $apps_tokens
      | select(
          $apps_tokens | any(. as $token |
            $project_names | any(. == $token)
            or ($project_norm | contains($token))
            or ($token | contains($project_norm))
          )
        )
      | {
          id: ($item.id // ""),
          name: ($item.name // ""),
          value: (
            ([$item.fields[]?
              | select((.name // "" | ascii_downcase) != ($apps_field | ascii_downcase))
              | .value
              | select(. != null and . != "")
            ][0]) // ($item.login.password // "")
          )
        }
      | @json
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
  while IFS= read -r item_json; do
    [[ -z "$item_json" ]] && continue
    item_id="$(printf '%s\n' "$item_json" | jq -r '.id // empty')"
    item_name="$(printf '%s\n' "$item_json" | jq -r '.name // empty')"
    item_value="$(printf '%s\n' "$item_json" | jq -r '.value // empty')"

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
  done <<< "$matching_items_jsonl"

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

SERVICE_SETUP_REQUIRED=0
if [[ "$QUICK_MODE" == "1" ]]; then
  service_probe="$(ssh "$HOST" "
    set -e
    LEGACY_SERVICE_LABELS=(${LEGACY_SERVICE_LABELS_SSH})
    SERVICE_LABELS=(${SERVICE_LABELS_SSH})
    current_found=1
    legacy_found=0

    systemd_unit_exists() {
      local unit=\"\$1\"
      [[ \"\$(systemctl --user show \"\$unit\" --property=LoadState --value 2>/dev/null || true)\" == 'loaded' ]]
    }

    if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
      UID_NUM=\"\$(id -u)\"
      for DOMAIN in \"gui/\$UID_NUM\" \"user/\$UID_NUM\"; do
        if ! launchctl print \"\$DOMAIN\" >/dev/null 2>&1; then
          continue
        fi
        domain_found=1
        for CURRENT_SERVICE_LABEL in \"\${SERVICE_LABELS[@]}\"; do
          [[ -n \"\$CURRENT_SERVICE_LABEL\" ]] || continue
          if ! launchctl print \"\$DOMAIN/\$CURRENT_SERVICE_LABEL\" >/dev/null 2>&1; then
            domain_found=0
          fi
        done
        if [[ \"\$domain_found\" == \"1\" ]]; then
          current_found=1
          break
        fi
        current_found=0
        for OLD_SERVICE_LABEL in \"\${LEGACY_SERVICE_LABELS[@]}\"; do
          [[ -n \"\$OLD_SERVICE_LABEL\" ]] || continue
          if launchctl print \"\$DOMAIN/\$OLD_SERVICE_LABEL\" >/dev/null 2>&1; then
            legacy_found=1
          fi
        done
      done
    elif command -v systemctl >/dev/null 2>&1; then
      for CURRENT_SERVICE_LABEL in \"\${SERVICE_LABELS[@]}\"; do
        [[ -n \"\$CURRENT_SERVICE_LABEL\" ]] || continue
        if ! systemd_unit_exists \"\${CURRENT_SERVICE_LABEL}.service\"; then
          current_found=0
        fi
      done
      for OLD_SERVICE_LABEL in \"\${LEGACY_SERVICE_LABELS[@]}\"; do
        [[ -n \"\$OLD_SERVICE_LABEL\" ]] || continue
        if systemd_unit_exists \"\${OLD_SERVICE_LABEL}.service\"; then
          legacy_found=1
        fi
      done
    fi

    printf '%s %s\n' \"\$current_found\" \"\$legacy_found\"
  " 2>/dev/null || true)"

  current_service_present="${service_probe%% *}"
  legacy_service_present="${service_probe##* }"

  if [[ "$current_service_present" != "1" || "$legacy_service_present" == "1" ]]; then
    SERVICE_SETUP_REQUIRED=1
    if [[ "$current_service_present" != "1" && "$legacy_service_present" == "1" ]]; then
      echo "==> Quick mode: current service label not found; migrating legacy service configuration..."
    elif [[ "$current_service_present" != "1" ]]; then
      echo "==> Quick mode: service configuration missing; recreating service..."
    else
      echo "==> Quick mode: legacy service labels detected; refreshing service configuration..."
    fi
  fi
fi

if [[ "$QUICK_MODE" == "1" && "$SERVICE_SETUP_REQUIRED" == "0" ]]; then
  echo "==> Quick mode: restarting existing service..."
  for ((idx = 1; idx <= ${#SERVICE_LABELS[@]}; idx++)); do
    current_startup_port="${SERVICE_STARTUP_PORTS[$idx]}"
    if [[ "$current_startup_port" == "__NONE__" ]]; then
      continue
    fi
    ensure_remote_port_available "$HOST" "$current_startup_port" "${SERVICE_LABELS[$idx]}"
  done
  ssh "$HOST" "
    set -e
    REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)
    BW_ENV_FILE=\"\$REMOTE_DIR_EXPANDED/${BW_REMOTE_ENV_FILE_NAME}\"
    STATIC_CONFIG_ENV_FILE=\"\$REMOTE_DIR_EXPANDED/.static-config-${PROJECT_NAME}.env.sh\"
    LEGACY_SERVICE_LABELS=(${LEGACY_SERVICE_LABELS_SSH})
    SERVICE_NAMES=(${SERVICE_NAMES_SSH})
    SERVICE_LABELS=(${SERVICE_LABELS_SSH})
    SERVICE_ENTRY_FILES=(${SERVICE_ENTRY_FILES_SSH})
    ARRAY_OFFSET=0
    if [[ -n \"\${ZSH_VERSION:-}\" ]]; then
      ARRAY_OFFSET=1
    fi
    SERVICE_COUNT=\${#SERVICE_LABELS[@]}

    detect_entry_file() {
      local requested_entry=\"\$1\"
      if [[ -n \"\$requested_entry\" && \"\$requested_entry\" != \"__AUTO__\" ]]; then
        local explicit_path=\"\$REMOTE_DIR_EXPANDED/\$requested_entry\"
        if [[ ! -f \"\$explicit_path\" ]]; then
          echo \"Error: Configured entry file not found: \$explicit_path\" >&2
          exit 1
        fi
        printf '%s\n' \"\$explicit_path\"
        return 0
      fi

      if [[ -f \"\$REMOTE_DIR_EXPANDED/server.js\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/server.js\"
      elif [[ -f \"\$REMOTE_DIR_EXPANDED/server.mjs\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/server.mjs\"
      elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.js\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/index.js\"
      elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.mjs\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/index.mjs\"
      else
        echo \"Error: No supported entry file found in \$REMOTE_DIR_EXPANDED\" >&2
        echo \"Checked: server.js, server.mjs, index.js, index.mjs\" >&2
        exit 1
      fi
    }

    build_wrapper() {
      local service_name=\"\$1\"
      local entry_file=\"\$2\"
      local start_wrapper=\"\$REMOTE_DIR_EXPANDED/.start-with-bw-env-\${service_name}.sh\"
      cat > \"\$start_wrapper\" << EOF_START_WRAPPER
#!/usr/bin/env bash
set -euo pipefail

if [[ -f \"\$STATIC_CONFIG_ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  source \"\$STATIC_CONFIG_ENV_FILE\"
fi

if [[ -f \"\$BW_ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  source \"\$BW_ENV_FILE\"
fi

exec \"\$(command -v node)\" \"\$entry_file\"
EOF_START_WRAPPER
      chmod 700 \"\$start_wrapper\"
      printf '%s\n' \"\$start_wrapper\"
    }

    if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
      UID_NUM=\"\$(id -u)\"
      for idx in \$(seq 0 \$((SERVICE_COUNT - 1))); do
        array_index=\$((idx + ARRAY_OFFSET))
        service_name=\"\${SERVICE_NAMES[\$array_index]}\"
        service_label=\"\${SERVICE_LABELS[\$array_index]}\"
        requested_entry=\"\${SERVICE_ENTRY_FILES[\$array_index]}\"
        entry_file=\"\$(detect_entry_file \"\$requested_entry\")\"
        build_wrapper \"\$service_name\" \"\$entry_file\" >/dev/null

        DOMAIN=''
        if launchctl print \"gui/\$UID_NUM/\$service_label\" >/dev/null 2>&1; then
          DOMAIN=\"gui/\$UID_NUM\"
        elif launchctl print \"user/\$UID_NUM/\$service_label\" >/dev/null 2>&1; then
          DOMAIN=\"user/\$UID_NUM\"
        else
          echo \"Error: launchd service not found: \$service_label\" >&2
          echo \"Checked domains: gui/\$UID_NUM and user/\$UID_NUM\" >&2
          echo \"Run a full deploy first to create/update service configuration.\" >&2
          exit 1
        fi
        echo \"Using launchd domain for \$service_label: \$DOMAIN\"
        launchctl kickstart -k \"\$DOMAIN/\$service_label\"
        sleep 1
        if ! launchctl print \"\$DOMAIN/\$service_label\" | grep -q 'state = running'; then
          echo \"Error: launchd service did not remain running: \$service_label\" >&2
          launchctl print \"\$DOMAIN/\$service_label\" || true
          exit 1
        fi
      done
      echo 'Services restarted via launchd'

    elif command -v systemctl >/dev/null 2>&1; then
      for idx in \$(seq 0 \$((SERVICE_COUNT - 1))); do
        array_index=\$((idx + ARRAY_OFFSET))
        service_name=\"\${SERVICE_NAMES[\$array_index]}\"
        service_label=\"\${SERVICE_LABELS[\$array_index]}\"
        requested_entry=\"\${SERVICE_ENTRY_FILES[\$array_index]}\"
        entry_file=\"\$(detect_entry_file \"\$requested_entry\")\"
        build_wrapper \"\$service_name\" \"\$entry_file\" >/dev/null

        if [[ \"\$(systemctl --user show \${service_label}.service --property=LoadState --value 2>/dev/null || true)\" != 'loaded' ]]; then
          echo \"Error: systemd service not found: \${service_label}.service\" >&2
          echo \"Run a full deploy first to create/update service configuration.\" >&2
          exit 1
        fi
        systemctl --user reset-failed \${service_label}.service >/dev/null 2>&1 || true
        systemctl --user restart \${service_label}.service
        sleep 1
        if ! systemctl --user is-active --quiet \${service_label}.service; then
          echo \"Error: systemd service did not remain active: \${service_label}.service\" >&2
          systemctl --user status \${service_label}.service --no-pager || true
          exit 1
        fi
      done
      echo 'Services restarted via systemd'

    else
      echo \"Error: Neither launchd nor systemd found. Cannot manage service.\" >&2
      exit 1
    fi
  "
else
  if [[ "$QUICK_MODE" == "1" ]]; then
    echo "==> Quick mode: setting up and restarting service..."
  else
    echo "==> Setting up and restarting services..."
  fi
  for ((idx = 1; idx <= ${#SERVICE_LABELS[@]}; idx++)); do
    current_startup_port="${SERVICE_STARTUP_PORTS[$idx]}"
    if [[ "$current_startup_port" == "__NONE__" ]]; then
      continue
    fi
    ensure_remote_port_available "$HOST" "$current_startup_port" "${SERVICE_LABELS[$idx]}"
  done
  ssh "$HOST" "
    set -e
    REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)
    BW_ENV_FILE=\"\$REMOTE_DIR_EXPANDED/${BW_REMOTE_ENV_FILE_NAME}\"
    STATIC_CONFIG_ENV_FILE=\"\$REMOTE_DIR_EXPANDED/.static-config-${PROJECT_NAME}.env.sh\"
    LEGACY_SERVICE_LABELS=(${LEGACY_SERVICE_LABELS_SSH})
    SERVICE_NAMES=(${SERVICE_NAMES_SSH})
    SERVICE_LABELS=(${SERVICE_LABELS_SSH})
    SERVICE_ENTRY_FILES=(${SERVICE_ENTRY_FILES_SSH})
    SERVICE_LOG_FILES=(${SERVICE_LOG_FILES_SSH})
    SERVICE_ERROR_LOG_FILES=(${SERVICE_ERROR_LOG_FILES_SSH})
    ARRAY_OFFSET=0
    if [[ -n \"\${ZSH_VERSION:-}\" ]]; then
      ARRAY_OFFSET=1
    fi
    SERVICE_COUNT=\${#SERVICE_LABELS[@]}

    detect_entry_file() {
      local requested_entry=\"\$1\"
      if [[ -n \"\$requested_entry\" && \"\$requested_entry\" != \"__AUTO__\" ]]; then
        local explicit_path=\"\$REMOTE_DIR_EXPANDED/\$requested_entry\"
        if [[ ! -f \"\$explicit_path\" ]]; then
          echo \"Error: Configured entry file not found: \$explicit_path\" >&2
          exit 1
        fi
        printf '%s\n' \"\$explicit_path\"
        return 0
      fi

      if [[ -f \"\$REMOTE_DIR_EXPANDED/server.js\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/server.js\"
      elif [[ -f \"\$REMOTE_DIR_EXPANDED/server.mjs\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/server.mjs\"
      elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.js\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/index.js\"
      elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.mjs\" ]]; then
        printf '%s\n' \"\$REMOTE_DIR_EXPANDED/index.mjs\"
      else
        echo \"Error: No supported entry file found in \$REMOTE_DIR_EXPANDED\" >&2
        echo \"Checked: server.js, server.mjs, index.js, index.mjs\" >&2
        exit 1
      fi
    }

    build_wrapper() {
      local service_name=\"\$1\"
      local entry_file=\"\$2\"
      local start_wrapper=\"\$REMOTE_DIR_EXPANDED/.start-with-bw-env-\${service_name}.sh\"
      cat > \"\$start_wrapper\" << EOF_START_WRAPPER
#!/usr/bin/env bash
set -euo pipefail

if [[ -f \"\$STATIC_CONFIG_ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  source \"\$STATIC_CONFIG_ENV_FILE\"
fi

if [[ -f \"\$BW_ENV_FILE\" ]]; then
  # shellcheck disable=SC1090
  source \"\$BW_ENV_FILE\"
fi

exec \"\$(command -v node)\" \"\$entry_file\"
EOF_START_WRAPPER
      chmod 700 \"\$start_wrapper\"
      printf '%s\n' \"\$start_wrapper\"
    }

    # Detect OS and use appropriate service manager
    if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
      echo \"==> Using launchd (macOS)\"
      UID_NUM=\"\$(id -u)\"
      DOMAIN=''
      HAVE_GUI_DOMAIN=0
      HAVE_USER_DOMAIN=0
      if launchctl print \"gui/\$UID_NUM\" >/dev/null 2>&1; then
        HAVE_GUI_DOMAIN=1
      fi
      if launchctl print \"user/\$UID_NUM\" >/dev/null 2>&1; then
        HAVE_USER_DOMAIN=1
      fi
      if [[ \"\$HAVE_GUI_DOMAIN\" -eq 0 && \"\$HAVE_USER_DOMAIN\" -eq 0 ]]; then
        echo \"Error: Could not find a usable launchd domain for this user.\" >&2
        exit 1
      fi
      echo \"Detected launchd domains: gui/\$UID_NUM=\$HAVE_GUI_DOMAIN user/\$UID_NUM=\$HAVE_USER_DOMAIN\"

      # Create LaunchAgent directory if it doesn't exist
      mkdir -p \"\$HOME/Library/LaunchAgents\"

      for OLD_SERVICE_LABEL in \"\${LEGACY_SERVICE_LABELS[@]}\"; do
        [[ -n \"\$OLD_SERVICE_LABEL\" ]] || continue
        [[ \"\$OLD_SERVICE_LABEL\" == \"${SERVICE_LABEL}\" ]] && continue
        echo \"Removing legacy launchd service: \$OLD_SERVICE_LABEL\"
        launchctl bootout \"gui/\$UID_NUM/\$OLD_SERVICE_LABEL\" 2>/dev/null || true
        launchctl bootout \"user/\$UID_NUM/\$OLD_SERVICE_LABEL\" 2>/dev/null || true
        rm -f \"\$HOME/Library/LaunchAgents/\${OLD_SERVICE_LABEL}.plist\"
      done

      write_launchd_service() {
        local service_label=\"\$1\"
        local service_name=\"\$2\"
        local service_log_file=\"\$3\"
        local service_error_log_file=\"\$4\"
        local start_wrapper=\"\$5\"
        local plist=\"\$HOME/Library/LaunchAgents/\${service_label}.plist\"
        cat > \"\$plist\" << 'EOF_PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key>
  <string>SERVICE_LABEL_PLACEHOLDER</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>START_WRAPPER_PLACEHOLDER</string>
  </array>
  <key>WorkingDirectory</key>
  <string>REMOTE_DIR_PLACEHOLDER</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>LOG_FILE_PLACEHOLDER</string>
  <key>StandardErrorPath</key>
  <string>ERROR_LOG_FILE_PLACEHOLDER</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF_PLIST
        sed -i '' \"s|REMOTE_DIR_PLACEHOLDER|\$REMOTE_DIR_EXPANDED|g\" \"\$plist\"
        sed -i '' \"s|START_WRAPPER_PLACEHOLDER|\$start_wrapper|g\" \"\$plist\"
        sed -i '' \"s|SERVICE_LABEL_PLACEHOLDER|\$service_label|g\" \"\$plist\"
        sed -i '' \"s|LOG_FILE_PLACEHOLDER|\$REMOTE_DIR_EXPANDED/\$service_log_file|g\" \"\$plist\"
        sed -i '' \"s|ERROR_LOG_FILE_PLACEHOLDER|\$REMOTE_DIR_EXPANDED/\$service_error_log_file|g\" \"\$plist\"
        if command -v plutil >/dev/null 2>&1; then
          if ! plutil -lint \"\$plist\" >/dev/null 2>&1; then
            echo \"Error: launchd plist is invalid: \$plist\" >&2
            plutil -lint \"\$plist\" >&2 || true
            exit 1
          fi
        fi
        printf '%s\n' \"\$plist\"
      }

      restart_launchd_service() {
        local service_label=\"\$1\"
        local plist=\"\$2\"
        local bootstrap_ok=0
        launchctl bootout \"gui/\$UID_NUM/\$service_label\" 2>/dev/null || true
        launchctl bootout \"user/\$UID_NUM/\$service_label\" 2>/dev/null || true
        for TRY_DOMAIN in \"gui/\$UID_NUM\" \"user/\$UID_NUM\"; do
          if ! launchctl print \"\$TRY_DOMAIN\" >/dev/null 2>&1; then
            continue
          fi
          echo \"Attempting launchd bootstrap for \$service_label in domain: \$TRY_DOMAIN\"
          set +e
          BOOTSTRAP_OUTPUT=\"\$(launchctl bootstrap \"\$TRY_DOMAIN\" \"\$plist\" 2>&1)\"
          BOOTSTRAP_STATUS=\$?
          set -e
          if [[ \"\$BOOTSTRAP_STATUS\" -ne 0 ]]; then
            echo \"Bootstrap failed in \$TRY_DOMAIN: \$BOOTSTRAP_OUTPUT\" >&2
            launchctl bootout \"\$TRY_DOMAIN/\$service_label\" 2>/dev/null || true
            continue
          fi
          launchctl enable \"\$TRY_DOMAIN/\$service_label\" || true
          launchctl kickstart -k \"\$TRY_DOMAIN/\$service_label\"
          if launchctl print \"\$TRY_DOMAIN/\$service_label\" >/dev/null 2>&1; then
            bootstrap_ok=1
            DOMAIN=\"\$TRY_DOMAIN\"
            break
          fi
        done
        if [[ \"\$bootstrap_ok\" -ne 1 ]]; then
          echo \"Error: launchd service did not load: \$service_label\" >&2
          echo \"Plist: \$plist\" >&2
          ls -l \"\$plist\" >&2 || true
          if command -v plutil >/dev/null 2>&1; then
            plutil -p \"\$plist\" >&2 || true
          fi
          exit 1
        fi
      }

      for idx in \$(seq 0 \$((SERVICE_COUNT - 1))); do
        array_index=\$((idx + ARRAY_OFFSET))
        service_name=\"\${SERVICE_NAMES[\$array_index]}\"
        service_label=\"\${SERVICE_LABELS[\$array_index]}\"
        service_log_file=\"\${SERVICE_LOG_FILES[\$array_index]}\"
        service_error_log_file=\"\${SERVICE_ERROR_LOG_FILES[\$array_index]}\"
        requested_entry=\"\${SERVICE_ENTRY_FILES[\$array_index]}\"
        entry_file=\"\$(detect_entry_file \"\$requested_entry\")\"
        start_wrapper=\"\$(build_wrapper \"\$service_name\" \"\$entry_file\")\"
        plist=\"\$(write_launchd_service \"\$service_label\" \"\$service_name\" \"\$service_log_file\" \"\$service_error_log_file\" \"\$start_wrapper\")\"
        restart_launchd_service \"\$service_label\" \"\$plist\"
      done
      echo \"Services loaded in launchd domain: \$DOMAIN\"
      echo 'Services restarted via launchd'

    elif command -v systemctl >/dev/null 2>&1; then
      echo \"==> Using systemd (Linux)\"

      # Create systemd user directory
      mkdir -p \"\$HOME/.config/systemd/user\"

      for OLD_SERVICE_LABEL in \"\${LEGACY_SERVICE_LABELS[@]}\"; do
        [[ -n \"\$OLD_SERVICE_LABEL\" ]] || continue
        [[ \"\$OLD_SERVICE_LABEL\" == \"${SERVICE_LABEL}\" ]] && continue
        echo \"Removing legacy systemd service: \${OLD_SERVICE_LABEL}.service\"
        systemctl --user disable \"\${OLD_SERVICE_LABEL}.service\" >/dev/null 2>&1 || true
        systemctl --user stop --no-block \"\${OLD_SERVICE_LABEL}.service\" >/dev/null 2>&1 || true
        rm -f \"\$HOME/.config/systemd/user/\${OLD_SERVICE_LABEL}.service\"
      done

      write_systemd_service() {
        local service_label=\"\$1\"
        local service_description=\"\$2\"
        local service_log_file=\"\$3\"
        local service_error_log_file=\"\$4\"
        local start_wrapper=\"\$5\"
        local service_file=\"\$HOME/.config/systemd/user/\${service_label}.service\"
        cat > \"\$service_file\" << EOF_SYSTEMD
[Unit]
Description=\${service_description}
After=network.target

[Service]
Type=simple
WorkingDirectory=\$REMOTE_DIR_EXPANDED
ExecStart=\${start_wrapper}
Restart=always
RestartSec=10
StandardOutput=append:\$REMOTE_DIR_EXPANDED/\${service_log_file}
StandardError=append:\$REMOTE_DIR_EXPANDED/\${service_error_log_file}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF_SYSTEMD
        printf '%s\n' \"\$service_file\"
      }

      for idx in \$(seq 0 \$((SERVICE_COUNT - 1))); do
        array_index=\$((idx + ARRAY_OFFSET))
        service_name=\"\${SERVICE_NAMES[\$array_index]}\"
        service_label=\"\${SERVICE_LABELS[\$array_index]}\"
        if [[ \"\$service_name\" == \"api\" ]]; then
          service_description=\"${PROJECT_NAME} API Service\"
        else
          service_description=\"${PROJECT_NAME} \${service_name} Service\"
        fi
        service_log_file=\"\${SERVICE_LOG_FILES[\$array_index]}\"
        service_error_log_file=\"\${SERVICE_ERROR_LOG_FILES[\$array_index]}\"
        requested_entry=\"\${SERVICE_ENTRY_FILES[\$array_index]}\"
        entry_file=\"\$(detect_entry_file \"\$requested_entry\")\"
        start_wrapper=\"\$(build_wrapper \"\$service_name\" \"\$entry_file\")\"
        write_systemd_service \"\$service_label\" \"\$service_description\" \"\$service_log_file\" \"\$service_error_log_file\" \"\$start_wrapper\" >/dev/null
      done
      systemctl --user daemon-reload
      for idx in \$(seq 0 \$((SERVICE_COUNT - 1))); do
        array_index=\$((idx + ARRAY_OFFSET))
        service_label=\"\${SERVICE_LABELS[\$array_index]}\"
        systemctl --user enable \"\${service_label}.service\"
        systemctl --user restart \"\${service_label}.service\"
        systemctl --user status \"\${service_label}.service\" --no-pager || true
      done
      echo 'Services restarted via systemd'

    else
      echo \"Error: Neither launchd nor systemd found. Cannot manage service.\" >&2
      exit 1
    fi
  "
fi

if [[ "$QUICK_MODE" == "1" ]]; then
  echo "==> Quick mode enabled; skipping healthcheck verification."
else
  echo "==> Verifying service healthchecks..."
  for ((idx = 1; idx <= ${#SERVICE_LABELS[@]}; idx++)); do
    current_service_name="${SERVICE_NAMES[$idx]}"
    current_startup_port="${SERVICE_STARTUP_PORTS[$idx]}"
    current_service_label="${SERVICE_LABELS[$idx]}"
    if [[ "$current_startup_port" == "__NONE__" ]]; then
      echo "   Skipping healthcheck for ${current_service_label} (${current_service_name}): no startup port configured."
      continue
    fi

    HEALTHCHECK_URL="http://localhost:${current_startup_port}/healthcheck"
    HEALTHCHECK_CMD="curl -sS --max-time 10 ${HEALTHCHECK_URL}"
    echo "   ${current_service_label} (${current_service_name}):"
    echo "   ssh ${HOST} '${HEALTHCHECK_CMD}'"

    healthcheck_ok=0
    healthcheck_last_output=""
    for attempt in {1..10}; do
      if healthcheck_last_output="$(ssh "$HOST" "$HEALTHCHECK_CMD" 2>&1)"; then
        if echo "$healthcheck_last_output" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"|\"ok\"[[:space:]]*:[[:space:]]*true'; then
          healthcheck_ok=1
          break
        fi
      fi
      sleep 2
    done

    if [[ "$healthcheck_ok" -eq 1 ]]; then
      echo "✅ Healthcheck OK for ${current_service_name} at ${HEALTHCHECK_URL}"
      echo "   Response: ${healthcheck_last_output}"
    else
      echo "❌ Healthcheck failed for ${current_service_name} at ${HEALTHCHECK_URL}" >&2
      if [[ -n "$healthcheck_last_output" ]]; then
        echo "   Last output: ${healthcheck_last_output}" >&2
      fi
      exit 1
    fi
  done
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
      GRAFANA_PROJECT_NAME="${GRAFANA_PROJECT_NAME:-$PROJECT_NAME}"
      GRAFANA_PROJECT_SLUG="${GRAFANA_PROJECT_SLUG:-$(sanitize_grafana_slug "$GRAFANA_PROJECT_NAME")}"
      GRAFANA_FOLDER_TITLE="${GRAFANA_FOLDER_TITLE:-$GRAFANA_PROJECT_NAME}"
      GRAFANA_FOLDER_UID="${GRAFANA_FOLDER_UID:-${GRAFANA_PROJECT_SLUG}-dashboards}"
      GRAFANA_PROM_DS_NAME="${GRAFANA_PROM_DS_NAME:-${GRAFANA_PROJECT_SLUG}-prometheus}"
      GRAFANA_PROM_DS_UID="${GRAFANA_PROM_DS_UID:-${GRAFANA_PROJECT_SLUG}-prometheus}"
      GRAFANA_PROM_SCRAPE_JOB_NAME="${GRAFANA_PROM_SCRAPE_JOB_NAME:-$GRAFANA_PROJECT_SLUG}"

      echo "==> Running Grafana dashboard import script..."
      echo "   Import script: ${DASHBOARD_SCRIPT}"
      echo "   Dashboard dir: ${PROJECT_DASHBOARD_DIR}"
      echo "   Grafana project: ${GRAFANA_PROJECT_NAME}"
      echo "   Grafana folder: ${GRAFANA_FOLDER_TITLE} (uid=${GRAFANA_FOLDER_UID})"
      echo "   Grafana datasource: ${GRAFANA_PROM_DS_NAME} (uid=${GRAFANA_PROM_DS_UID})"
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

      AUTO_PROM_METRICS_PORTS=()
      for current_metrics_port in "${SERVICE_METRICS_PORTS[@]}"; do
        if [[ "$current_metrics_port" == "__NONE__" || -z "$current_metrics_port" ]]; then
          continue
        fi
        AUTO_PROM_METRICS_PORTS+=("$current_metrics_port")
      done
      if [[ ${#AUTO_PROM_METRICS_PORTS[@]} -eq 0 && -n "${METRICS_PORT:-}" ]]; then
        AUTO_PROM_METRICS_PORTS=("$METRICS_PORT")
      fi
      typeset -U AUTO_PROM_METRICS_PORTS

      if [[ -n "$AUTO_PROM_HOST_IP" ]]; then
        AUTO_PROM_SCRAPE_HOST="$AUTO_PROM_HOST_IP"
      elif [[ -n "$AUTO_PROM_GW" ]]; then
        AUTO_PROM_SCRAPE_HOST="$AUTO_PROM_GW"
      else
        AUTO_PROM_SCRAPE_HOST="host.docker.internal"
      fi

      AUTO_PROM_SCRAPE_TARGETS_ARR=()
      for current_metrics_port in "${AUTO_PROM_METRICS_PORTS[@]}"; do
        AUTO_PROM_SCRAPE_TARGETS_ARR+=("${AUTO_PROM_SCRAPE_HOST}:${current_metrics_port}")
      done
      AUTO_PROM_SCRAPE_TARGET="${AUTO_PROM_SCRAPE_TARGETS_ARR[1]}"
      AUTO_PROM_SCRAPE_TARGETS="${(j:,:)AUTO_PROM_SCRAPE_TARGETS_ARR}"

      echo "   Prometheus config: ${AUTO_PROM_CONFIG_FILE}"
      echo "   Host IP candidate: ${AUTO_PROM_HOST_IP:-<none>}"
      echo "   Docker GW fallback: ${AUTO_PROM_GW:-<none>}"
      echo "   Prometheus scrape targets: ${AUTO_PROM_SCRAPE_TARGETS}"

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
        for AUTO_PROM_SCRAPE_PORT in "${AUTO_PROM_METRICS_PORTS[@]}"; do
          echo "   Ensuring firewall allows ${AUTO_PROM_SUBNET} -> tcp/${AUTO_PROM_SCRAPE_PORT}"
          ssh "$HOST" "sudo iptables -C INPUT -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT"
        done
      fi

      if [[ -z "${GRAFANA_PASSWORD:-}" && "$BW_ENV_SYNC" == "1" ]]; then
        ensure_bw_session
        grafana_bw_item_name="${GRAFANA_BW_ITEM_NAME:-GRAFANA_LOGIN}"
        grafana_bw_item_json="$(run_bw_with_session list items --search "$grafana_bw_item_name" 2>/dev/null \
          | jq -r --arg name "$grafana_bw_item_name" '.[] | select(.name == $name) | .login.password // empty' \
          | head -1)"
        if [[ -n "$grafana_bw_item_json" ]]; then
          GRAFANA_PASSWORD="$grafana_bw_item_json"
          echo "   Loaded GRAFANA_PASSWORD from Bitwarden item '$grafana_bw_item_name'"
        else
          echo "   Warning: GRAFANA_PASSWORD not set and Bitwarden item '$grafana_bw_item_name' not found or has no password" >&2
        fi
      fi
      if [[ -z "${GRAFANA_PASSWORD:-}" && "$BW_ENV_SYNC" != "1" ]]; then
        echo "   Skipping GRAFANA_PASSWORD Bitwarden lookup; pass bw/--bw to enable Bitwarden credentials."
      fi

      GRAFANA_IMPORT_URL="${GRAFANA_URL:-}"
      GRAFANA_TUNNEL_PID=""
      GRAFANA_IMPORT_HOST_HEADER="${GRAFANA_HOST_HEADER:-}"
      GRAFANA_IMPORT_FORWARDED_PREFIX="${GRAFANA_FORWARDED_PREFIX:-}"
      if [[ -z "$GRAFANA_IMPORT_URL" ]]; then
        GRAFANA_TUNNEL_PORT="$(find_free_local_port)"
        GRAFANA_IMPORT_URL="http://127.0.0.1:${GRAFANA_TUNNEL_PORT}"
        GRAFANA_IMPORT_HOST_HEADER="${GRAFANA_IMPORT_HOST_HEADER:-api.skynolimit.dev}"
        GRAFANA_IMPORT_FORWARDED_PREFIX="${GRAFANA_IMPORT_FORWARDED_PREFIX:-/grafana}"
        echo "   Grafana URL: ${GRAFANA_IMPORT_URL} (SSH tunnel to ${HOST}:127.0.0.1:3001)"
        ssh -o ExitOnForwardFailure=yes -N \
          -L "127.0.0.1:${GRAFANA_TUNNEL_PORT}:127.0.0.1:3001" \
          "$HOST" &
        GRAFANA_TUNNEL_PID="$!"

        tunnel_ready=0
        for _ in {1..20}; do
          if curl -sS --max-time 2 "${GRAFANA_IMPORT_URL}/api/health" >/dev/null 2>&1; then
            tunnel_ready=1
            break
          fi
          sleep 0.25
        done

        if [[ "$tunnel_ready" != "1" ]]; then
          if [[ -n "$GRAFANA_TUNNEL_PID" ]]; then
            kill "$GRAFANA_TUNNEL_PID" >/dev/null 2>&1 || true
            wait "$GRAFANA_TUNNEL_PID" 2>/dev/null || true
          fi
          echo "Error: Grafana SSH tunnel did not become ready at ${GRAFANA_IMPORT_URL}" >&2
          exit 1
        fi
      else
        echo "   Grafana URL: ${GRAFANA_IMPORT_URL}"
      fi

      set +e
      DEPLOY_HOST="$HOST" \
      PROJECT_NAME="$GRAFANA_PROJECT_NAME" \
      PROJECT_SLUG="$GRAFANA_PROJECT_SLUG" \
      FOLDER_TITLE="$GRAFANA_FOLDER_TITLE" \
      FOLDER_UID="$GRAFANA_FOLDER_UID" \
      PROM_DS_NAME="$GRAFANA_PROM_DS_NAME" \
      PROM_DS_UID="$GRAFANA_PROM_DS_UID" \
      PROM_SCRAPE_JOB_NAME="$GRAFANA_PROM_SCRAPE_JOB_NAME" \
      METRICS_PORT="$METRICS_PORT" \
      DASHBOARD_DIR="$PROJECT_DASHBOARD_DIR" \
      PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-${AUTO_PROM_CONFIG_FILE}}" \
      PROM_SCRAPE_TARGETS="${PROM_SCRAPE_TARGETS:-${AUTO_PROM_SCRAPE_TARGETS}}" \
      PROM_SCRAPE_TARGET="${PROM_SCRAPE_TARGET:-${AUTO_PROM_SCRAPE_TARGET}}" \
      GRAFANA_URL="$GRAFANA_IMPORT_URL" \
      GRAFANA_HOST_HEADER="$GRAFANA_IMPORT_HOST_HEADER" \
      GRAFANA_FORWARDED_PROTO="${GRAFANA_FORWARDED_PROTO:-https}" \
      GRAFANA_FORWARDED_PREFIX="$GRAFANA_IMPORT_FORWARDED_PREFIX" \
      GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}" \
        "$DASHBOARD_SCRIPT"
      dashboard_status="$?"
      set -e

      if [[ -n "$GRAFANA_TUNNEL_PID" ]]; then
        kill "$GRAFANA_TUNNEL_PID" >/dev/null 2>&1 || true
        wait "$GRAFANA_TUNNEL_PID" 2>/dev/null || true
      fi
      if [[ "$dashboard_status" -ne 0 ]]; then
        exit "$dashboard_status"
      fi
    fi
  else
    echo "==> No Grafana dashboard import script found (checked ${LOCAL_DASHBOARD_SCRIPT} and ${CENTRAL_DASHBOARD_SCRIPT}), skipping..."
  fi
fi

echo "✅ Deploy complete."
notify_deploy_complete "$PROJECT_NAME" "$HOST"

if [[ "$TAIL_MODE" == "1" ]]; then
  TAIL_SCRIPT="$SCRIPT_DIR/tail_node_project.zsh"
  if [[ ! -f "$TAIL_SCRIPT" ]]; then
    echo "Error: Tail script not found: $TAIL_SCRIPT" >&2
    exit 1
  fi

  TAIL_ARGS=("$PROJECT_NAME" "$HOST")
  if [[ "$TAIL_ERRORS_ONLY" == "1" ]]; then
    TAIL_ARGS+=("--errors-only")
  fi
  tail_with_redeploy_controls "$TAIL_SCRIPT" "${TAIL_ARGS[@]}"
fi
