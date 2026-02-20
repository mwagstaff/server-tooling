#!/usr/bin/env zsh
set -euo pipefail
setopt typeset_silent

SCRIPT_DIR="${0:a:h}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-15}"
LATENCY_SLO_MS="${LATENCY_SLO_MS:-1000}"
WINDOWS_SECONDS=(600 1800 3600 86400)
WINDOW_LABELS=("10m" "30m" "1h" "24h")
CLEAR_SCREEN=1
PRUNE_EVERY=50
TARGET_URI=""
LOG_FILE=""
CURL_EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Continuously probe a URI and render rolling availability/latency metrics.

Usage:
  ./uri-watch.zsh --uri <target-uri> [options]

Options:
  --uri <uri>                    Target URI to probe (required)
  --interval <seconds>           Probe interval (default: 30)
  --timeout <seconds>            Curl max-time (default: 15)
  --latency-slo-ms <milliseconds>
                                 Success latency threshold for latency % (default: 1000)
  --log-file <path>              CSV log file path (default: ./logs/<sanitized-host>.csv)
  --header "<Name: Value>"       Extra HTTP header (repeatable)
  --no-clear                     Do not clear screen between updates
  -h, --help                     Show this help

Success criteria:
  - HTTP status < 400 is success
  - HTTP status >= 400 is failure
  - Curl/network errors are failures
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

is_number() {
  [[ "$1" == <-> || "$1" == <->.<-> ]]
}

sanitize_for_filename() {
  local raw="$1"
  local out
  out="$(echo "$raw" | tr '/:?#&=%@' '_' | tr -cs '[:alnum:]_.-' '_')"
  if [[ -z "$out" ]]; then
    out="target"
  fi
  echo "$out"
}

ensure_log_file() {
  if [[ -z "$LOG_FILE" ]]; then
    local base
    base="$(sanitize_for_filename "$TARGET_URI")"
    LOG_FILE="$SCRIPT_DIR/logs/${base}.csv"
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "epoch,iso_utc,http_code,latency_ms,success,curl_exit,error" > "$LOG_FILE"
  fi
}

color_for_percent() {
  local pct="$1"
  if [[ "$pct" == "n/a" ]]; then
    printf '\033[90m'
    return
  fi

  local pct_num="$pct"
  if (( $(awk -v p="$pct_num" 'BEGIN { print (p >= 99.0) ? 1 : 0 }') )); then
    printf '\033[32m'
  elif (( $(awk -v p="$pct_num" 'BEGIN { print (p >= 95.0) ? 1 : 0 }') )); then
    printf '\033[33m'
  else
    printf '\033[31m'
  fi
}

format_percent() {
  local raw="$1"
  if (( $(awk -v x="$raw" 'BEGIN { print (x < 0) ? 1 : 0 }') )); then
    echo "n/a"
  else
    printf "%.2f%%" "$raw"
  fi
}

format_ms() {
  local raw="$1"
  if (( $(awk -v x="$raw" 'BEGIN { print (x < 0) ? 1 : 0 }') )); then
    echo "n/a"
  else
    printf "%.1f ms" "$raw"
  fi
}

bar_for_percent() {
  local pct="$1"
  local width=24
  if [[ "$pct" == "n/a" ]]; then
    printf '%*s' "$width" '' | tr ' ' '.'
    return
  fi

  local pct_num="${pct%%%}"
  local filled
  filled="$(awk -v p="$pct_num" -v w="$width" 'BEGIN { f=int((p*w)/100 + 0.5); if (f < 0) f=0; if (f > w) f=w; print f }')"

  local full
  local empty
  full="$(printf '%*s' "$filled" '' | tr ' ' '#')"
  empty="$(printf '%*s' "$((width - filled))" '' | tr ' ' '.')"
  printf '%s%s' "$full" "$empty"
}

compute_stats() {
  local now_epoch="$1"
  awk -F, \
    -v now="$now_epoch" \
    -v slo_ms="$LATENCY_SLO_MS" \
    -v w1="${WINDOWS_SECONDS[1]}" \
    -v w2="${WINDOWS_SECONDS[2]}" \
    -v w3="${WINDOWS_SECONDS[3]}" \
    -v w4="${WINDOWS_SECONDS[4]}" '
BEGIN {
  split("10m 30m 1h 24h", labels, " ")
  windows[1]=w1
  windows[2]=w2
  windows[3]=w3
  windows[4]=w4
}
NR > 1 {
  ts=$1 + 0
  lat=$4 + 0
  ok=$5 + 0
  for (i=1; i<=4; i++) {
    if (ts >= (now - windows[i])) {
      total[i]++
      success[i] += ok
      fail[i] += (ok ? 0 : 1)
      if (ok) {
        latency_count[i]++
        latency_sum[i] += lat
        if (lat <= slo_ms) {
          latency_ok[i]++
        }
        if (lat > latency_max[i]) {
          latency_max[i] = lat
        }
      }
    }
  }
}
END {
  for (i=1; i<=4; i++) {
    if (total[i] > 0) {
      availability_pct = (success[i] / total[i]) * 100
    } else {
      availability_pct = -1
    }

    if (latency_count[i] > 0) {
      latency_pct = (latency_ok[i] / latency_count[i]) * 100
      latency_avg = latency_sum[i] / latency_count[i]
      latency_peak = latency_max[i]
    } else {
      latency_pct = -1
      latency_avg = -1
      latency_peak = -1
    }

    printf "%s|%d|%d|%d|%.4f|%.4f|%.4f|%.4f\n", labels[i], total[i], success[i], fail[i], availability_pct, latency_pct, latency_avg, latency_peak
  }
}' "$LOG_FILE"
}

print_dashboard() {
  local now_epoch="$1"
  local now_iso="$2"
  local last_line="$3"
  local total_checks="$4"
  local total_failures="$5"
  local stats_output="$6"

  if (( CLEAR_SCREEN )); then
    print -n -- $'\033[2J\033[H'
  fi

  echo "URI Availability Monitor"
  echo "Target URI: $TARGET_URI"
  echo "Interval: ${INTERVAL_SECONDS}s | Timeout: ${REQUEST_TIMEOUT_SECONDS}s | Latency SLO: ${LATENCY_SLO_MS}ms"
  echo "Log file: $LOG_FILE"
  echo "Current UTC: $now_iso"
  echo

  if [[ -n "$last_line" ]]; then
    local last_iso last_code last_latency last_success last_error
    IFS=',' read -r _epoch last_iso last_code last_latency last_success _curl_exit last_error <<< "$last_line"
    if [[ "$last_success" == "1" ]]; then
      printf "Last check: \033[32mSUCCESS\033[0m at %s | HTTP %s | %s ms\n" "$last_iso" "$last_code" "$last_latency"
    else
      printf "Last check: \033[31mFAILURE\033[0m at %s | HTTP %s | %s ms | %s\n" "$last_iso" "$last_code" "$last_latency" "${last_error:-error}"
    fi
  else
    echo "Last check: no samples yet"
  fi

  echo "Total checks: $total_checks | Total failures: $total_failures"
  echo

  printf "%-8s %-8s %-8s %-8s %-15s %-15s %-12s %-12s\n" \
    "Window" "Checks" "OK" "Fail" "Availability" "Latency %" "Avg Lat" "Max Lat"
  printf "%-8s %-8s %-8s %-8s %-15s %-15s %-12s %-12s\n" \
    "------" "------" "--" "----" "------------" "---------" "-------" "-------"

  while IFS='|' read -r label total ok fail availability_raw latency_raw avg_raw max_raw; do
    [[ -n "$label" ]] || continue

    local availability latency_pct availability_num latency_num
    availability="$(format_percent "$availability_raw")"
    latency_pct="$(format_percent "$latency_raw")"
    availability_num="${availability%%%}"
    latency_num="${latency_pct%%%}"

    local avail_color latency_color reset
    avail_color="$(color_for_percent "$availability_num")"
    latency_color="$(color_for_percent "$latency_num")"
    reset=$'\033[0m'

    printf "%-8s %-8s %-8s %-8s %s%-15s%s %s%-15s%s %-12s %-12s\n" \
      "$label" "$total" "$ok" "$fail" \
      "$avail_color" "$availability" "$reset" \
      "$latency_color" "$latency_pct" "$reset" \
      "$(format_ms "$avg_raw")" "$(format_ms "$max_raw")"

    printf "         avail [%s]  lat [%s]\n" \
      "$(bar_for_percent "$availability")" "$(bar_for_percent "$latency_pct")"
  done <<< "$stats_output"

  echo
  echo "Ctrl+C to stop."
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --uri)
        [[ $# -ge 2 ]] || die "--uri requires a value"
        TARGET_URI="$2"
        shift 2
        ;;
      --interval)
        [[ $# -ge 2 ]] || die "--interval requires a value"
        INTERVAL_SECONDS="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires a value"
        REQUEST_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --latency-slo-ms)
        [[ $# -ge 2 ]] || die "--latency-slo-ms requires a value"
        LATENCY_SLO_MS="$2"
        shift 2
        ;;
      --log-file)
        [[ $# -ge 2 ]] || die "--log-file requires a value"
        LOG_FILE="$2"
        shift 2
        ;;
      --header)
        [[ $# -ge 2 ]] || die "--header requires a value"
        CURL_EXTRA_ARGS+=(-H "$2")
        shift 2
        ;;
      --no-clear)
        CLEAR_SCREEN=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$TARGET_URI" ]] || die "--uri is required"
  is_number "$INTERVAL_SECONDS" || die "--interval must be numeric"
  is_number "$REQUEST_TIMEOUT_SECONDS" || die "--timeout must be numeric"
  is_number "$LATENCY_SLO_MS" || die "--latency-slo-ms must be numeric"
}

prune_log() {
  local now_epoch="$1"
  local keep_after="$((now_epoch - WINDOWS_SECONDS[4] - 3600))"
  local tmp_file="${LOG_FILE}.tmp"
  awk -F, -v cutoff="$keep_after" 'NR == 1 || ($1 + 0) >= cutoff' "$LOG_FILE" > "$tmp_file"
  mv "$tmp_file" "$LOG_FILE"
}

run_probe_loop() {
  local iteration=0

  while true; do
    local started_epoch started_iso curl_out curl_exit http_code latency_seconds latency_ms success error_message
    started_epoch="$(date -u +%s)"
    started_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local curl_stderr_file
    curl_stderr_file="$(mktemp)"
    if curl_out="$(curl -sS -o /dev/null --max-time "$REQUEST_TIMEOUT_SECONDS" "${CURL_EXTRA_ARGS[@]}" -w '%{http_code} %{time_total}' "$TARGET_URI" 2>"$curl_stderr_file")"; then
      curl_exit=0
    else
      curl_exit=$?
    fi
    error_message="$(tr '\n' ' ' < "$curl_stderr_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    rm -f "$curl_stderr_file"

    if [[ -n "$curl_out" ]]; then
      http_code="${curl_out%% *}"
      latency_seconds="${curl_out##* }"
    else
      http_code="000"
      latency_seconds="0"
    fi

    latency_ms="$(awk -v sec="$latency_seconds" 'BEGIN { printf "%.3f", sec * 1000 }')"

    if (( curl_exit == 0 )) && [[ "$http_code" == <-> ]] && (( http_code < 400 )); then
      success=1
      error_message=""
    else
      success=0
      if [[ -z "$error_message" ]]; then
        error_message="http_status_${http_code}"
      fi
    fi

    local escaped_error
    escaped_error="$(echo "$error_message" | sed 's/,/;/g')"
    echo "${started_epoch},${started_iso},${http_code},${latency_ms},${success},${curl_exit},${escaped_error}" >> "$LOG_FILE"

    local now_epoch now_iso total_checks total_failures stats_output last_line
    now_epoch="$(date -u +%s)"
    now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    total_checks="$(awk -F, 'NR > 1 { c++ } END { print c + 0 }' "$LOG_FILE")"
    total_failures="$(awk -F, 'NR > 1 { f += ($5 == 1 ? 0 : 1) } END { print f + 0 }' "$LOG_FILE")"
    stats_output="$(compute_stats "$now_epoch")"
    last_line="$(tail -n 1 "$LOG_FILE" 2>/dev/null || true)"

    print_dashboard "$now_epoch" "$now_iso" "$last_line" "$total_checks" "$total_failures" "$stats_output"

    iteration=$((iteration + 1))
    if (( iteration % PRUNE_EVERY == 0 )); then
      prune_log "$now_epoch"
    fi

    sleep "$INTERVAL_SECONDS"
  done
}

main() {
  parse_args "$@"
  ensure_log_file
  run_probe_loop
}

main "$@"
