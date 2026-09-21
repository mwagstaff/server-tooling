#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
SCRIPT_NAME="${0:t}"
CONFIG_FILE="$SCRIPT_DIR/config/node_projects.json"
PROJECT_NAME="train-track-planner-mvp"
HOST="${PLANNER_MVP_HOST:-mini}"
NODE_VERSION="${PLANNER_MVP_NODE_VERSION:-24.21.0}"
RUNS="${PLANNER_MVP_RUNS:-3}"

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME preflight|runtime|deploy|dataset|smoke|load [--admission-cap 1-100]|all

Environment overrides:
  PLANNER_MVP_HOST             SSH host (default: mini)
  PLANNER_MVP_NODE_VERSION     Node 24 release (default: 24.21.0)
  PLANNER_MVP_DATASET_SOURCE   Local validated snapshot directory
  PLANNER_MVP_ORIGIN           Smoke origin (default: KTH)
  PLANNER_MVP_DESTINATION      Smoke destination (default: VIC)
  PLANNER_MVP_COMPLEX_ROUTES   Comma-separated ORG-DST pairs for queued fallback checks
  PLANNER_MVP_RUNS             Timed runs per algorithm, 1-20 (default: 3)
  PLANNER_MVP_ALGORITHMS       original,raptor (default), or either one
  PLANNER_MVP_NO_CACHE         1 clears search-result caches before every request
  PLANNER_MVP_LOAD_LEVELS      Concurrent-user stages (default: 5,10,20,50)

The load action clears result caches, checks Mongo search logs for zero hits,
and exits non-zero if any search fails, times out, or is rejected. An admission
override applies only for the test and is restored automatically.
EOF
}

[[ -f "$CONFIG_FILE" ]] || { echo "Missing deployment configuration: $CONFIG_FILE" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
[[ "$NODE_VERSION" == 24.* ]] || { echo "PLANNER_MVP_NODE_VERSION must select Node 24." >&2; exit 1; }
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 && "$RUNS" -le 20 ]] || { echo "PLANNER_MVP_RUNS must be between 1 and 20." >&2; exit 1; }
ALGORITHMS="${PLANNER_MVP_ALGORITHMS:-original,raptor}"
NO_CACHE="${PLANNER_MVP_NO_CACHE:-0}"
[[ "$ALGORITHMS" =~ '^(original|raptor)(,(original|raptor))*$' ]] || { echo "PLANNER_MVP_ALGORITHMS must contain original and/or raptor." >&2; exit 1; }
[[ "$NO_CACHE" == 0 || "$NO_CACHE" == 1 ]] || { echo "PLANNER_MVP_NO_CACHE must be 0 or 1." >&2; exit 1; }

project_value() {
  jq -r --arg name "$PROJECT_NAME" --arg key "$1" '.[] | select(.name == $name) | .[$key] // empty' "$CONFIG_FILE"
}

static_value() {
  jq -r --arg name "$PROJECT_NAME" --arg key "$1" '.[] | select(.name == $name) | .static_env[$key] // empty' "$CONFIG_FILE"
}

LOCAL_API_DIR="$(project_value path)"
REMOTE_DIR="$(project_value remote_dir)"
NODE_BINARY="$(project_value node_binary)"
SECRET_NAME="$(project_value bw_remote_env_file_name)"
DATA_DIR="$(static_value PLANNER_DATA_DIR)"
PORT="$(static_value PORT)"
SOURCE_DATASET="${PLANNER_MVP_DATASET_SOURCE:-$LOCAL_API_DIR/var/planner/snapshots/RJTTF939-compact-v2}"
SECRET_FILE="$REMOTE_DIR/$SECRET_NAME"
STATIC_FILE="$REMOTE_DIR/.static-config-${PROJECT_NAME}.env.sh"

for value in "$LOCAL_API_DIR" "$REMOTE_DIR" "$NODE_BINARY" "$SECRET_NAME" "$DATA_DIR" "$PORT"; do
  [[ -n "$value" ]] || { echo "The $PROJECT_NAME deployment definition is incomplete." >&2; exit 1; }
done

dataset_version() {
  [[ -f "$SOURCE_DATASET/metadata.json" && -f "$SOURCE_DATASET/validation.json" ]] || {
    echo "Validated MVP snapshot not found: $SOURCE_DATASET" >&2; exit 1;
  }
  jq -e '.valid == true' "$SOURCE_DATASET/validation.json" >/dev/null || {
    echo "MVP snapshot validation is not successful: $SOURCE_DATASET" >&2; exit 1;
  }
  jq -er '.version | select(test("^[a-f0-9]{64}$"))' "$SOURCE_DATASET/metadata.json"
}

install_runtime() {
  echo "==> Installing verified Node $NODE_VERSION runtime on $HOST"
  ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$NODE_VERSION" "$NODE_BINARY" <<'REMOTE'
set -euo pipefail
version="$1"
node_binary="$2"
runtime_link="${node_binary:h:h}"
runtime_root="${runtime_link:h}"
archive="node-v${version}-darwin-arm64.tar.gz"
version_dir="$runtime_root/node-v${version}-darwin-arm64"
if [[ -e "$runtime_link" && ! -L "$runtime_link" ]]; then
  echo "Refusing to replace non-symlink runtime path: $runtime_link" >&2
  exit 1
fi
if [[ -x "$version_dir/bin/node" ]]; then
  actual="$($version_dir/bin/node --version)"
  [[ "$actual" == "v$version" ]] || { echo "Unexpected existing runtime: $actual" >&2; exit 1; }
else
  temporary="$(mktemp -d)"
  trap 'rm -rf "$temporary"' EXIT
  curl --fail --silent --show-error --location "https://nodejs.org/dist/v${version}/${archive}" --output "$temporary/$archive"
  curl --fail --silent --show-error --location "https://nodejs.org/dist/v${version}/SHASUMS256.txt" --output "$temporary/SHASUMS256.txt"
  expected="$(awk -v archive="$archive" '$2 == archive { print $1 }' "$temporary/SHASUMS256.txt")"
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { echo "Published Node checksum was not found." >&2; exit 1; }
  actual="$(shasum -a 256 "$temporary/$archive" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] || { echo "Node archive checksum mismatch." >&2; exit 1; }
  mkdir -p "$runtime_root"
  tar -xzf "$temporary/$archive" -C "$runtime_root"
fi
ln -sfn "$version_dir" "$runtime_link"
"$node_binary" -e "require('node:sqlite'); console.log('runtime=' + process.version + ' sqlite=available')"
REMOTE
}

ensure_secret() {
  echo "==> Ensuring a host-local MVP service token exists"
  ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$REMOTE_DIR" "$SECRET_FILE" <<'REMOTE'
set -euo pipefail
remote_dir="$1"
secret_file="$2"
mkdir -p "$remote_dir"
if [[ -f "$secret_file" ]] && grep -q '^export PLANNER_SERVICE_TOKEN=' "$secret_file"; then
  chmod 600 "$secret_file"
  echo "token=existing"
  exit 0
fi
umask 077
token="$(openssl rand -hex 32)"
temporary="${secret_file}.new.$$"
if [[ -f "$secret_file" ]]; then cp "$secret_file" "$temporary"; else print '# Local Mini MVP credentials; not managed by Bitwarden.' > "$temporary"; fi
print "export PLANNER_SERVICE_TOKEN=$token" >> "$temporary"
mv "$temporary" "$secret_file"
chmod 600 "$secret_file"
echo "token=created"
REMOTE
}

deploy_service() {
  install_runtime
  ensure_secret
  echo "==> Deploying the isolated planner MVP to $HOST"
  GRAFANA_DASHBOARD_DIR=/dev/null "$SCRIPT_DIR/node_project.zsh" "$PROJECT_NAME" "$HOST" --full --no-tail
}

stage_dataset() {
  local version remote_dataset
  local -a rsync_progress
  version="$(dataset_version)"
  remote_dataset="$DATA_DIR/snapshots/$version"
  echo "==> Copying validated snapshot ${version[1,12]} to $HOST"
  ssh -o ConnectTimeout=10 "$HOST" "mkdir -p '$remote_dataset' '$DATA_DIR'"
  if [[ "$(rsync --help 2>&1)" == *'--info='* ]]; then
    rsync_progress=(--info=progress2)
  else
    rsync_progress=(--progress)
  fi
  rsync -a --delete "${rsync_progress[@]}" "$SOURCE_DATASET/" "$HOST:$remote_dataset/"
  echo "==> Validating and activating the Mini-local pointer"
  ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$REMOTE_DIR" "$NODE_BINARY" "$remote_dataset" "$DATA_DIR" <<'REMOTE'
set -euo pipefail
remote_dir="$1"
node_binary="$2"
dataset="$3"
data_dir="$4"
cd "$remote_dir"
"$node_binary" scripts/planner.js validate --dataset "$dataset"
"$node_binary" scripts/planner.js activate --dataset "$dataset" --data-dir "$data_dir"
REMOTE
  "$SCRIPT_DIR/start_node_project.zsh" "$PROJECT_NAME" "$HOST"
}

smoke() {
  local report_dir report_file timestamp origin destination complex_routes
  report_dir="/Users/mwagstaff/.local/share/train-track-planner/mvp-reports"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  report_file="$report_dir/$timestamp.json"
  origin="${PLANNER_MVP_ORIGIN:-KTH}"
  destination="${PLANNER_MVP_DESTINATION:-VIC}"
  complex_routes="${PLANNER_MVP_COMPLEX_ROUTES:-KTH-INV,ABD-PNZ,CLK-CDB,HHD-NRW}"
  echo "==> Running authenticated functional and performance checks on $HOST"
  ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$REMOTE_DIR" "$STATIC_FILE" "$SECRET_FILE" "$NODE_BINARY" "$PORT" \
    "$origin" "$destination" "$RUNS" "$complex_routes" "$report_dir" "$report_file" "$ALGORITHMS" "$NO_CACHE" <<'REMOTE'
set -euo pipefail
remote_dir="$1"
static_file="$2"
secret_file="$3"
node_binary="$4"
port="$5"
origin="$6"
destination="$7"
runs="$8"
complex_routes="$9"
report_dir="${10}"
report_file="${11}"
algorithms="${12}"
no_cache="${13}"
source "$static_file"
source "$secret_file"
mkdir -p "$report_dir"
cd "$remote_dir"
args=(--base-url "http://127.0.0.1:$port" \
  --origin "$origin" --destination "$destination" --runs "$runs" \
  --complex-routes "$complex_routes" --algorithms "$algorithms" --output "$report_file")
if [[ "$no_cache" == 1 ]]; then args+=(--no-cache); fi
"$node_binary" scripts/planner-service-smoke.js "${args[@]}"
echo "Report: $report_file"
REMOTE
}

load_test() {
  local report_dir report_file timestamp levels admission_cap
  admission_cap=""
  while (( $# )); do
    case "$1" in
      --admission-cap)
        (( $# >= 2 )) || { echo 'Missing value for --admission-cap.' >&2; exit 1; }
        admission_cap="$2"
        shift 2 ;;
      *) echo "Unknown load option: $1" >&2; usage; exit 1 ;;
    esac
  done
  if [[ -n "$admission_cap" && ! "$admission_cap" =~ '^[0-9]+$' ]] || \
     [[ -n "$admission_cap" && ( "$admission_cap" -lt 1 || "$admission_cap" -gt 100 ) ]]; then
    echo 'Admission cap must be an integer from 1 to 100.' >&2; exit 1
  fi
  report_dir="/Users/mwagstaff/.local/share/train-track-planner/mvp-reports"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  report_file="$report_dir/load-$timestamp.json"
  levels="${PLANNER_MVP_LOAD_LEVELS:-5,10,20,50}"
  echo "==> Running bounded RAPTOR load stages on $HOST ($levels simultaneous users${admission_cap:+, admission cap $admission_cap})"
  ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$REMOTE_DIR" "$STATIC_FILE" "$SECRET_FILE" "$NODE_BINARY" "$PORT" \
    "$levels" "$report_dir" "$report_file" "$admission_cap" <<'REMOTE'
set -euo pipefail
remote_dir="$1"
static_file="$2"
secret_file="$3"
node_binary="$4"
port="$5"
levels="$6"
report_dir="$7"
report_file="$8"
admission_cap="$9"
source "$static_file"
source "$secret_file"
pid="$(/usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN -t)"
[[ "$pid" =~ '^[0-9]+$' ]] || { echo 'Expected exactly one Mini planner listener.' >&2; exit 1; }
mkdir -p "$report_dir"
cd "$remote_dir"
args=(--base-url "http://127.0.0.1:$port" --pid "$pid" --levels "$levels" --output "$report_file")
if [[ -n "$admission_cap" ]]; then args+=(--admission-cap "$admission_cap"); fi
"$node_binary" scripts/planner-service-load.js "${args[@]}"
REMOTE
}

preflight() {
  local version
  version="$(dataset_version)"
  echo "Local dataset: $SOURCE_DATASET"
  echo "Dataset version: $version"
  echo "Remote host: $HOST"
  ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$NODE_BINARY" "$DATA_DIR" "$SECRET_FILE" "$PORT" <<'REMOTE'
set -u
node_binary="$1"
data_dir="$2"
secret_file="$3"
port="$4"
failures=0
check() { if eval "$2"; then echo "ok: $1"; else echo "missing: $1"; failures=$((failures + 1)); fi }
check 'Darwin arm64 host' '[[ "$(uname -s)-$(uname -m)" == Darwin-arm64 ]]'
check 'pinned Node runtime with node:sqlite' '[[ -x "$node_binary" ]] && "$node_binary" -e "require(\"node:sqlite\")" >/dev/null 2>&1'
check 'Mini-local active timetable pointer' '[[ -f "$data_dir/active.json" ]]'
check 'MVP service token' '[[ -f "$secret_file" ]] && grep -q "^export PLANNER_SERVICE_TOKEN=" "$secret_file"'
check 'Mini-local Mongo credentials' '[[ -f "$secret_file" ]] && grep -q "^export MONGODB_URI_TRAIN_TRACK_UK=" "$secret_file"'
uid="$(id -u)"
check 'MVP LaunchAgent loaded' 'launchctl print "gui/$uid/com.train-track-planner.mvp" >/dev/null 2>&1 || launchctl print "user/$uid/com.train-track-planner.mvp" >/dev/null 2>&1'
check 'planner liveness on loopback' 'curl --fail --silent --max-time 3 "http://127.0.0.1:$port/healthcheck" >/dev/null 2>&1'
if [[ -e "$data_dir" ]]; then df -h "$data_dir" | tail -1; else df -h "$HOME" | tail -1; fi
exit "$failures"
REMOTE
}

action="${1:-preflight}"
if (( $# )); then shift; fi
case "$action" in
  preflight) preflight ;;
  runtime) install_runtime ;;
  deploy) deploy_service ;;
  dataset) stage_dataset ;;
  smoke) smoke ;;
  load) load_test "$@" ;;
  all) deploy_service; stage_dataset; smoke; preflight ;;
  help|--help|-h) usage ;;
  *) usage; exit 1 ;;
esac
