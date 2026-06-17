#!/usr/bin/env bash
set -euo pipefail

# Analyze host and Node.js app performance over passwordless SSH.
# Usage:
#   ./monitoring/analyze-node-performance.sh [HOST] [OPTIONS]
#
# Examples:
#   ./monitoring/analyze-node-performance.sh
#   ./monitoring/analyze-node-performance.sh sky --duration 15
#   ./monitoring/analyze-node-performance.sh api01 --pid 12345 --output-dir reports

TARGET_HOST="${TARGET_HOST:-sky}"
DURATION=10
PID=""
OUTPUT_DIR="."
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

usage() {
  cat <<'EOF'
Usage:
  ./monitoring/analyze-node-performance.sh [HOST] [OPTIONS]

Options:
  --duration SECONDS  Sampling duration for vmstat/perf/strace checks (default: 10)
  --pid PID           Prefer a specific process for perf/strace sampling
  --output-dir DIR    Directory for the generated Markdown report (default: .)
  -h, --help          Show this help

Environment:
  TARGET_HOST         Default host when HOST is omitted (default: sky)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --duration" >&2
        exit 1
      fi
      DURATION="$2"
      shift 2
      ;;
    --pid)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --pid" >&2
        exit 1
      fi
      PID="$2"
      shift 2
      ;;
    --output-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --output-dir" >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      TARGET_HOST="$1"
      shift
      ;;
  esac
done

if ! [[ "${DURATION}" =~ ^[0-9]+$ ]] || [[ "${DURATION}" -lt 3 ]]; then
  echo "--duration must be an integer >= 3" >&2
  exit 1
fi

if [[ -n "${PID}" ]] && ! [[ "${PID}" =~ ^[0-9]+$ ]]; then
  echo "--pid must be numeric" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

if ! ssh "${SSH_OPTS[@]}" "${TARGET_HOST}" "exit" 2>/dev/null; then
  echo "Error: cannot connect to ${TARGET_HOST} with passwordless SSH." >&2
  exit 1
fi

REMOTE_HOSTNAME="$(ssh "${SSH_OPTS[@]}" "${TARGET_HOST}" "hostname -f 2>/dev/null || hostname" | tr -d '\r' | head -n 1)"
if [[ -z "${REMOTE_HOSTNAME}" ]]; then
  REMOTE_HOSTNAME="${TARGET_HOST}"
fi

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_HOSTNAME="$(printf '%s' "${REMOTE_HOSTNAME}" | tr -c '[:alnum:]._-' '_')"
OUT_FILE="${OUTPUT_DIR%/}/${UTC_STAMP}_${SAFE_HOSTNAME}_performance.md"
TMP_FILE="$(mktemp "${OUT_FILE}.tmp.XXXXXX")"

cleanup() {
  rm -f "${TMP_FILE}"
}
trap cleanup EXIT

echo "==> Analyzing ${TARGET_HOST} (${REMOTE_HOSTNAME}) for ${DURATION}s"
echo "==> Report: ${OUT_FILE}"
echo

ssh "${SSH_OPTS[@]}" "${TARGET_HOST}" \
  "ANALYSIS_DURATION=${DURATION} TARGET_PID=${PID} bash -s" >"${TMP_FILE}" <<'REMOTE_SCRIPT'
set -u

DURATION="${ANALYSIS_DURATION:-10}"
TARGET_PID="${TARGET_PID:-}"
REPORT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
KERNEL="$(uname -srmo 2>/dev/null || uname -a)"

SUDO=()
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SUDO=(sudo -n)
fi
SUDO_PREFIX=""
if [ "${#SUDO[@]}" -gt 0 ]; then
  SUDO_PREFIX="$(printf '%q ' "${SUDO[@]}")"
fi

have() {
  command -v "$1" >/dev/null 2>&1
}

capture() {
  local title="$1"
  shift
  echo
  echo "### ${title}"
  echo
  echo '```text'
  "$@" 2>&1 || true
  echo '```'
}

first_line() {
  awk 'NF {print; exit}'
}

read_cpu_count() {
  if have nproc; then
    nproc 2>/dev/null || echo 1
  else
    grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
  fi
}

read_load1() {
  awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
}

read_mem_used_pct() {
  awk '
    /^MemTotal:/ {total=$2}
    /^MemAvailable:/ {avail=$2}
    END {
      if (total > 0) printf "%.0f", ((total - avail) / total) * 100;
      else print 0;
    }
  ' /proc/meminfo 2>/dev/null
}

read_swap_used_pct() {
  awk '
    /^SwapTotal:/ {total=$2}
    /^SwapFree:/ {free=$2}
    END {
      if (total > 0) printf "%.0f", ((total - free) / total) * 100;
      else print 0;
    }
  ' /proc/meminfo 2>/dev/null
}

read_disk_alerts() {
  df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 {
    pct=$5; sub(/%/, "", pct);
    if (pct >= 85) print $6 " is " pct "% full";
  }'
}

node_pids() {
  if [ -n "${TARGET_PID}" ]; then
    if [ -r "/proc/${TARGET_PID}/comm" ]; then
      printf '%s\n' "${TARGET_PID}"
    fi
    return
  fi

  if have pgrep; then
    pgrep -f '(^|/)(node|npm|pnpm|yarn)( |$)' 2>/dev/null || true
  else
    ps -eo pid=,comm=,args= 2>/dev/null | awk '$2 ~ /^(node|npm|pnpm|yarn)$/ || $0 ~ /\/node / {print $1}'
  fi
}

process_cmd() {
  local pid="$1"
  tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//'
}

select_hot_pid() {
  local candidates
  candidates="$(node_pids | awk 'NF' | sort -u)"
  if [ -z "${candidates}" ]; then
    ps -eo pid=,%cpu=,comm= --sort=-%cpu 2>/dev/null | awk 'NR==1 {print $1; exit}'
    return
  fi

  ps -eo pid=,%cpu= --sort=-%cpu 2>/dev/null | awk -v pids="${candidates}" '
    BEGIN {
      n=split(pids, a, "\n");
      for (i=1; i<=n; i++) wanted[a[i]]=1;
    }
    wanted[$1] {print $1; exit}
  '
}

render_table_header() {
  echo "| Check | Status | Detail |"
  echo "|---|---|---|"
}

status_row() {
  printf '| %s | %s | %s |\n' "$1" "$2" "$3"
}

CPU_COUNT="$(read_cpu_count | first_line)"
LOAD1="$(read_load1 | first_line)"
MEM_USED_PCT="$(read_mem_used_pct | first_line)"
SWAP_USED_PCT="$(read_swap_used_pct | first_line)"
DISK_ALERTS="$(read_disk_alerts)"
HOT_PID="$(select_hot_pid | first_line)"

if [ -z "${CPU_COUNT}" ] || ! printf '%s' "${CPU_COUNT}" | grep -Eq '^[0-9]+$'; then
  CPU_COUNT=1
fi
if [ -z "${LOAD1}" ]; then
  LOAD1=0
fi
if [ -z "${MEM_USED_PCT}" ]; then
  MEM_USED_PCT=0
fi
if [ -z "${SWAP_USED_PCT}" ]; then
  SWAP_USED_PCT=0
fi

LOAD_STATUS="OK"
LOAD_DETAIL="1m load ${LOAD1} across ${CPU_COUNT} CPU(s)."
if awk -v load_avg="${LOAD1}" -v cpus="${CPU_COUNT}" 'BEGIN {exit !(load_avg >= cpus * 1.5)}'; then
  LOAD_STATUS="Investigate"
  LOAD_DETAIL="1m load ${LOAD1} is >= 1.5x CPU count (${CPU_COUNT})."
elif awk -v load_avg="${LOAD1}" -v cpus="${CPU_COUNT}" 'BEGIN {exit !(load_avg >= cpus)}'; then
  LOAD_STATUS="Watch"
  LOAD_DETAIL="1m load ${LOAD1} is at or above CPU count (${CPU_COUNT})."
fi

MEM_STATUS="OK"
MEM_DETAIL="Memory use ${MEM_USED_PCT}%, swap use ${SWAP_USED_PCT}%."
if [ "${MEM_USED_PCT}" -ge 90 ] || [ "${SWAP_USED_PCT}" -ge 25 ]; then
  MEM_STATUS="Investigate"
elif [ "${MEM_USED_PCT}" -ge 80 ] || [ "${SWAP_USED_PCT}" -gt 0 ]; then
  MEM_STATUS="Watch"
fi

DISK_STATUS="OK"
DISK_DETAIL="No non-tmpfs filesystem is >= 85% full."
if [ -n "${DISK_ALERTS}" ]; then
  DISK_STATUS="Investigate"
  DISK_DETAIL="$(printf '%s\n' "${DISK_ALERTS}" | awk 'BEGIN {sep=""} NF {printf "%s%s", sep, $0; sep="; "} END {print ""}')"
fi

TOOLS_STATUS="OK"
MISSING_TOOLS=""
for tool in perf strace iostat pidstat; do
  if ! have "${tool}"; then
    MISSING_TOOLS="${MISSING_TOOLS}${MISSING_TOOLS:+, }${tool}"
  fi
done
if [ -n "${MISSING_TOOLS}" ]; then
  TOOLS_STATUS="Limited"
fi

echo "# Performance Analysis: ${HOSTNAME_FQDN}"
echo
echo "- Generated: ${REPORT_UTC}"
echo "- Kernel: ${KERNEL}"
echo "- User: $(id -un 2>/dev/null || true)"
echo "- Sampling duration: ${DURATION}s"
if [ -n "${HOT_PID}" ]; then
  echo "- Primary sampled PID: ${HOT_PID} ($(process_cmd "${HOT_PID}" | cut -c 1-180))"
else
  echo "- Primary sampled PID: none found"
fi
echo
echo "## Concise Summary"
echo
render_table_header
status_row "CPU/load" "${LOAD_STATUS}" "${LOAD_DETAIL}"
status_row "Memory/swap" "${MEM_STATUS}" "${MEM_DETAIL}"
status_row "Disk capacity" "${DISK_STATUS}" "${DISK_DETAIL}"
status_row "Profiling tools" "${TOOLS_STATUS}" "${MISSING_TOOLS:-perf, strace, iostat, and pidstat are available.}"
echo
echo "## Recommendations"
echo
if [ "${LOAD_STATUS}" = "Investigate" ]; then
  echo "- CPU pressure is high. Inspect the top CPU process list and perf output below; for Node.js, look for synchronous CPU-heavy code, JSON serialization, compression, crypto, regex backtracking, or tight loops."
elif [ "${LOAD_STATUS}" = "Watch" ]; then
  echo "- CPU pressure is near capacity. Check whether this is expected traffic, then profile the hottest Node.js process during a busy window."
else
  echo "- CPU load is within a normal range for the available CPU count."
fi

if [ "${MEM_STATUS}" = "Investigate" ]; then
  echo "- Memory pressure is high. For Node.js, capture heap snapshots from the app, check container or system memory limits, and review recent deploys for leaks or unbounded caches."
elif [ "${MEM_STATUS}" = "Watch" ]; then
  echo "- Memory or swap usage is worth watching. Validate Node.js max-old-space-size, cache sizes, and worker/process counts."
else
  echo "- Memory and swap usage do not currently indicate pressure."
fi

if [ "${DISK_STATUS}" = "Investigate" ]; then
  echo "- Disk capacity is a risk. Rotate or prune logs, old deploys, package caches, Docker data, and database backups before troubleshooting deeper."
else
  echo "- Disk capacity is not currently the primary concern."
fi

if [ -n "${MISSING_TOOLS}" ]; then
  echo "- Install missing tools for stronger evidence: ${MISSING_TOOLS}. On Debian/Ubuntu this is usually sysstat, strace, and linux-tools matching the running kernel."
fi

if [ -z "${HOT_PID}" ]; then
  echo "- No Node.js PID was found. Re-run with --pid if the app runs under a wrapper, container, or nonstandard process name."
fi

echo
echo "## Host Snapshot"
capture "Uptime and Load" uptime
capture "CPU and Memory Pressure (vmstat)" sh -c "vmstat 1 ${DURATION}"
capture "Top CPU Processes" sh -c "ps -eo pid,ppid,user,stat,%cpu,%mem,etime,comm,args --sort=-%cpu | head -n 16"
capture "Top Memory Processes" sh -c "ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,etime,comm,args --sort=-rss | head -n 16"
capture "Memory" free -h
capture "Filesystems" df -hT -x tmpfs -x devtmpfs

if have lsblk; then
  capture "Block Devices" lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,ROTA,MODEL
fi

echo
echo "## Disk I/O"
if have iostat; then
  capture "iostat" sh -c "iostat -xz 1 ${DURATION}"
else
  capture "Disk Counters" sh -c "cat /proc/diskstats"
fi

if have pidstat; then
  capture "Per-process I/O (pidstat)" sh -c "pidstat -d 1 ${DURATION}"
fi

echo
echo "## Node.js Processes"
if node_pids | awk 'NF' >/tmp/node-pids.$$; then
  :
fi
if [ -s /tmp/node-pids.$$ ]; then
  echo
  echo "| PID | CPU % | MEM % | RSS KB | FDs | Elapsed | Command |"
  echo "|---:|---:|---:|---:|---:|---|---|"
  while IFS= read -r pid; do
    [ -r "/proc/${pid}/status" ] || continue
    ps_line="$(ps -p "${pid}" -o %cpu=,%mem=,rss=,etime= 2>/dev/null || true)"
    fd_count="$(find "/proc/${pid}/fd" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
    cmd="$(process_cmd "${pid}" | sed 's/|/\\|/g' | cut -c 1-160)"
    cpu="$(printf '%s\n' "${ps_line}" | awk '{print $1}')"
    mem="$(printf '%s\n' "${ps_line}" | awk '{print $2}')"
    rss="$(printf '%s\n' "${ps_line}" | awk '{print $3}')"
    etime="$(printf '%s\n' "${ps_line}" | awk '{print $4}')"
    printf '| %s | %s | %s | %s | %s | %s | `%s` |\n' "${pid}" "${cpu:-?}" "${mem:-?}" "${rss:-?}" "${fd_count:-?}" "${etime:-?}" "${cmd:-?}"
  done </tmp/node-pids.$$
else
  echo
  echo "No Node.js processes were detected by process name or command line."
fi
rm -f /tmp/node-pids.$$

if [ -n "${HOT_PID}" ] && [ -r "/proc/${HOT_PID}/status" ]; then
  echo
  echo "## Process Detail: ${HOT_PID}"
  capture "Process Status" sh -c "cat /proc/${HOT_PID}/status"
  capture "Process Limits" sh -c "cat /proc/${HOT_PID}/limits"
  capture "Open File Descriptor Count" sh -c "find /proc/${HOT_PID}/fd -maxdepth 1 -type l 2>/dev/null | wc -l"

  if have lsof; then
    capture "Top Open Files" sh -c "lsof -p ${HOT_PID} 2>/dev/null | head -n 40"
  fi

  echo
  echo "## Hotspot Sampling"
  if have perf; then
    capture "perf stat" sh -c "timeout $((DURATION + 3))s ${SUDO_PREFIX}perf stat -p ${HOT_PID} -- sleep ${DURATION}"
    capture "perf top symbols" sh -c "tmp=\$(mktemp); if timeout $((DURATION + 5))s ${SUDO_PREFIX}perf record -F 49 -g -p ${HOT_PID} -o \"\$tmp\" -- sleep ${DURATION} >/dev/null 2>&1; then ${SUDO_PREFIX}perf report -i \"\$tmp\" --stdio --no-children --sort comm,dso,symbol 2>/dev/null | head -n 80; else echo 'perf record failed; check perf_event_paranoid, kernel symbols, or permissions.'; fi; rm -f \"\$tmp\""
  else
    echo
    echo "### perf"
    echo
    echo '```text'
    echo "perf is not installed."
    echo '```'
  fi

  if have strace; then
    capture "strace syscall summary" sh -c "timeout -s INT ${DURATION}s ${SUDO_PREFIX}strace -qq -f -c -p ${HOT_PID} -o /tmp/strace-summary-${HOT_PID} >/dev/null 2>&1; ${SUDO_PREFIX}cat /tmp/strace-summary-${HOT_PID} 2>/dev/null || echo 'strace attach failed; check ptrace permissions or process ownership.'; ${SUDO_PREFIX}rm -f /tmp/strace-summary-${HOT_PID}"
  else
    echo
    echo "### strace"
    echo
    echo '```text'
    echo "strace is not installed."
    echo '```'
  fi
fi

echo
echo "## Service and Container Context"
if have systemctl; then
  capture "Failed systemd Units" sh -c "systemctl --failed --no-pager"
fi
if have docker; then
  capture "Docker Containers" sh -c "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' 2>/dev/null || docker ps"
fi
if have pm2; then
  capture "PM2 Processes" sh -c "pm2 jlist 2>/dev/null | node -e \"let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{for(const p of JSON.parse(s)){console.log([p.pid,p.name,p.pm2_env?.status,p.monit?.cpu,p.monit?.memory,p.pm2_env?.restart_time].join('\\t'))}}catch(e){console.log(s)}})\""
fi

echo
echo "## Recent Kernel and OOM Signals"
if have journalctl; then
  capture "Kernel warnings/errors" sh -c "journalctl -k --since '2 hours ago' --no-pager 2>/dev/null | grep -Ei 'oom|killed process|blocked for more than|hung task|nvme|i/o error|ext4|xfs|reset|throttle' | tail -n 80"
else
  capture "dmesg warnings/errors" sh -c "dmesg 2>/dev/null | grep -Ei 'oom|killed process|blocked for more than|hung task|nvme|i/o error|ext4|xfs|reset|throttle' | tail -n 80"
fi

echo
echo "## Interpretation Notes"
echo
echo "- High load with low CPU usage often points to disk I/O wait, blocked network filesystems, or process contention."
echo "- High Node.js CPU in perf without useful JavaScript frames still confirms where time is spent at the native/runtime level; use a Node.js CPU profile or inspector snapshot for source-level attribution."
echo "- Heavy strace time in epoll_wait with low CPU is usually idle waiting, not a bottleneck. Heavy read/write/fsync/connect/futex time is more actionable."
echo "- If the process runs inside a container, host-level perf/strace may need root or container PID namespace access."
REMOTE_SCRIPT

awk '
  /^# / || /^- Generated:/ || /^- Kernel:/ || /^- Sampling duration:/ {
    print
    next
  }
  /^## Concise Summary/ {
    printing=1
  }
  /^## Host Snapshot/ {
    printing=0
  }
  printing {
    print
  }
' "${TMP_FILE}"

mv "${TMP_FILE}" "${OUT_FILE}"
trap - EXIT

echo
echo "==> Wrote ${OUT_FILE}"
