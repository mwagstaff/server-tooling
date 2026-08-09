#!/usr/bin/env bash
set -euo pipefail

# Print Redis key groups sorted by memory usage, then key count.
#
# Usage:
#   ./collection-stats.sh [HOST]
#
# Defaults:
#   HOST sky
#
# Environment:
#   REDIS_CONTAINER          Redis container name (default: redis-server)
#   REDIS_DATABASES          Space-separated database numbers to inspect. By
#                            default, all databases with keys are inspected.
#   REDIS_KEY_PATTERN        SCAN pattern (default: *)
#   REDIS_GROUP_DEPTH        Number of colon-delimited key parts to group by
#                            (default: 1)
#   REDIS_TOP_KEYS           Number of largest individual keys to show
#                            (default: 25)
#   REDIS_MEMORY_SAMPLES     Samples for MEMORY USAGE (default: 5)
#   REDIS_WARN_NO_TTL        Set to 0 to suppress no-TTL warnings.
#   REDISCLI_AUTH            Optional Redis password, passed through to redis-cli.

HOST="${1:-sky}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis-server}"
REDIS_DATABASES="${REDIS_DATABASES:-}"
REDIS_KEY_PATTERN="${REDIS_KEY_PATTERN:-*}"
REDIS_GROUP_DEPTH="${REDIS_GROUP_DEPTH:-1}"
REDIS_TOP_KEYS="${REDIS_TOP_KEYS:-25}"
REDIS_MEMORY_SAMPLES="${REDIS_MEMORY_SAMPLES:-5}"
REDIS_WARN_NO_TTL="${REDIS_WARN_NO_TTL:-1}"
REDISCLI_AUTH="${REDISCLI_AUTH:-}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

if [ "$#" -gt 1 ]; then
  die "Usage: $0 [HOST]"
fi

if ! [[ "${REDIS_GROUP_DEPTH}" =~ ^[0-9]+$ ]] || [ "${REDIS_GROUP_DEPTH}" -lt 1 ]; then
  die "REDIS_GROUP_DEPTH must be a positive integer"
fi

if ! [[ "${REDIS_TOP_KEYS}" =~ ^[0-9]+$ ]]; then
  die "REDIS_TOP_KEYS must be a non-negative integer"
fi

if ! [[ "${REDIS_MEMORY_SAMPLES}" =~ ^[0-9]+$ ]] || [ "${REDIS_MEMORY_SAMPLES}" -lt 1 ]; then
  die "REDIS_MEMORY_SAMPLES must be a positive integer"
fi

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_OPTS[@]}" "${HOST}" "exit" 2>/dev/null; then
  die "Cannot connect to ${HOST}"
fi

remote_args=()
for arg in \
  "${REDIS_CONTAINER}" \
  "${REDIS_DATABASES:-__ALL_DATABASES__}" \
  "${REDIS_KEY_PATTERN}" \
  "${REDIS_GROUP_DEPTH}" \
  "${REDIS_TOP_KEYS}" \
  "${REDIS_MEMORY_SAMPLES}" \
  "${REDIS_WARN_NO_TTL}" \
  "${REDISCLI_AUTH}"; do
  printf -v quoted_arg "%q" "${arg}"
  remote_args+=("${quoted_arg}")
done

ssh "${SSH_OPTS[@]}" "${HOST}" "bash -s -- ${remote_args[*]}" <<'REMOTE'
set -euo pipefail

REDIS_CONTAINER="${1}"
REDIS_DATABASES="${2}"
REDIS_KEY_PATTERN="${3}"
REDIS_GROUP_DEPTH="${4}"
REDIS_TOP_KEYS="${5}"
REDIS_MEMORY_SAMPLES="${6}"
REDIS_WARN_NO_TTL="${7}"
REDISCLI_AUTH_VALUE="${8}"

if [ "${REDIS_DATABASES}" = "__ALL_DATABASES__" ]; then
  REDIS_DATABASES=""
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or not on PATH" >&2
  exit 1
fi

if ! sudo docker ps --format '{{.Names}}' | grep -qx "${REDIS_CONTAINER}"; then
  echo "Redis container is not running: ${REDIS_CONTAINER}" >&2
  exit 1
fi

if [ -n "${REDISCLI_AUTH_VALUE}" ]; then
  auth_probe="$(
    sudo docker exec \
      -e REDISCLI_AUTH="${REDISCLI_AUTH_VALUE}" \
      "${REDIS_CONTAINER}" \
      redis-cli --raw PING 2>&1 || true
  )"

  case "${auth_probe}" in
    *"AUTH <password> called without any password configured"*)
      echo "Ignoring REDISCLI_AUTH because this Redis server has no password configured." >&2
      REDISCLI_AUTH_VALUE=""
      ;;
    *PONG*)
      ;;
    *)
      printf "Redis auth check failed:\n%s\n" "${auth_probe}" >&2
      exit 1
      ;;
  esac
fi

docker_redis_cli() {
  if [ -n "${REDISCLI_AUTH_VALUE}" ]; then
    sudo docker exec -e REDISCLI_AUTH="${REDISCLI_AUTH_VALUE}" "${REDIS_CONTAINER}" redis-cli --raw "$@"
  else
    sudo docker exec "${REDIS_CONTAINER}" redis-cli --raw "$@"
  fi
}

scan_database() {
  local db="${1}"

  if [ -n "${REDISCLI_AUTH_VALUE}" ]; then
    sudo docker exec \
      -e REDISCLI_AUTH="${REDISCLI_AUTH_VALUE}" \
      -i \
      "${REDIS_CONTAINER}" \
      sh -s -- "${db}" "${REDIS_KEY_PATTERN}" "${REDIS_MEMORY_SAMPLES}" <<'CONTAINER'
set -eu

db="${1}"
pattern="${2}"
memory_samples="${3}"
scanned=0

redis() {
  redis-cli --raw -n "${db}" "$@"
}

key_metric() {
  key="${1}"
  type="${2}"

  case "${type}" in
    string) redis STRLEN "${key}" 2>/dev/null || printf "0" ;;
    list) redis LLEN "${key}" 2>/dev/null || printf "0" ;;
    set) redis SCARD "${key}" 2>/dev/null || printf "0" ;;
    zset) redis ZCARD "${key}" 2>/dev/null || printf "0" ;;
    hash) redis HLEN "${key}" 2>/dev/null || printf "0" ;;
    stream) redis XLEN "${key}" 2>/dev/null || printf "0" ;;
    *) printf "" ;;
  esac
}

redis --scan --pattern "${pattern}" | while IFS= read -r key; do
  [ -n "${key}" ] || continue
  scanned=$((scanned + 1))
  if [ $((scanned % 1000)) -eq 0 ]; then
    echo "Scanned db${db}: ${scanned} matched keys so far..." >&2
  fi

  type="$(redis TYPE "${key}" 2>/dev/null || printf "none")"
  if [ "${type}" = "none" ]; then
    continue
  fi

  memory="$(redis MEMORY USAGE "${key}" SAMPLES "${memory_samples}" 2>/dev/null || printf "0")"
  ttl="$(redis TTL "${key}" 2>/dev/null || printf "-2")"
  metric="$(key_metric "${key}" "${type}")"

  printf "G\t%s\t%s\t%s\t%s\t%s\n" "${db}" "${key}" "${memory:-0}" "${ttl}" "${type}"
  printf "T\t%s\t%s\t%s\t%s\t%s\t%s\n" "${memory:-0}" "${db}" "${type}" "${metric}" "${ttl}" "${key}"
done
CONTAINER
  else
    sudo docker exec \
      -i \
      "${REDIS_CONTAINER}" \
      sh -s -- "${db}" "${REDIS_KEY_PATTERN}" "${REDIS_MEMORY_SAMPLES}" <<'CONTAINER'
set -eu

db="${1}"
pattern="${2}"
memory_samples="${3}"
scanned=0

redis() {
  redis-cli --raw -n "${db}" "$@"
}

key_metric() {
  key="${1}"
  type="${2}"

  case "${type}" in
    string) redis STRLEN "${key}" 2>/dev/null || printf "0" ;;
    list) redis LLEN "${key}" 2>/dev/null || printf "0" ;;
    set) redis SCARD "${key}" 2>/dev/null || printf "0" ;;
    zset) redis ZCARD "${key}" 2>/dev/null || printf "0" ;;
    hash) redis HLEN "${key}" 2>/dev/null || printf "0" ;;
    stream) redis XLEN "${key}" 2>/dev/null || printf "0" ;;
    *) printf "" ;;
  esac
}

redis --scan --pattern "${pattern}" | while IFS= read -r key; do
  [ -n "${key}" ] || continue
  scanned=$((scanned + 1))
  if [ $((scanned % 1000)) -eq 0 ]; then
    echo "Scanned db${db}: ${scanned} matched keys so far..." >&2
  fi

  type="$(redis TYPE "${key}" 2>/dev/null || printf "none")"
  if [ "${type}" = "none" ]; then
    continue
  fi

  memory="$(redis MEMORY USAGE "${key}" SAMPLES "${memory_samples}" 2>/dev/null || printf "0")"
  ttl="$(redis TTL "${key}" 2>/dev/null || printf "-2")"
  metric="$(key_metric "${key}" "${type}")"

  printf "G\t%s\t%s\t%s\t%s\t%s\n" "${db}" "${key}" "${memory:-0}" "${ttl}" "${type}"
  printf "T\t%s\t%s\t%s\t%s\t%s\t%s\n" "${memory:-0}" "${db}" "${type}" "${metric}" "${ttl}" "${key}"
done
CONTAINER
  fi
}

format_bytes() {
  awk -v bytes="${1:-0}" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ");
      value = bytes + 0;
      unit = 1;
      while (value >= 1024 && unit < 5) {
        value /= 1024;
        unit += 1;
      }
      if (unit == 1 || value >= 10) {
        printf "%.0f %s", value, units[unit];
      } else {
        printf "%.1f %s", value, units[unit];
      }
    }'
}

format_ttl() {
  local seconds="${1:-}"
  if [ -z "${seconds}" ]; then
    printf ""
  elif [ "${seconds}" -lt 0 ]; then
    printf "%s" "${seconds}"
  elif [ "${seconds}" -lt 60 ]; then
    printf "%ss" "${seconds}"
  elif [ "${seconds}" -lt 3600 ]; then
    printf "%sm" "$((seconds / 60))"
  elif [ "${seconds}" -lt 86400 ]; then
    printf "%sh" "$((seconds / 3600))"
  else
    printf "%sd" "$((seconds / 86400))"
  fi
}

key_group() {
  awk -v depth="${REDIS_GROUP_DEPTH}" '
    {
      n = split($0, parts, ":");
      if (n < depth) {
        print $0;
        next;
      }
      group = parts[1];
      for (i = 2; i <= depth; i += 1) {
        group = group ":" parts[i];
      }
      print group;
    }'
}

list_databases() {
  if [ -n "${REDIS_DATABASES}" ]; then
    printf "%s\n" ${REDIS_DATABASES}
    return
  fi

  docker_redis_cli INFO keyspace \
    | awk -F '[:,=]' '/^db[0-9]+:/ && $3 > 0 { sub(/^db/, "", $1); print $1 }' \
    | sort -n
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

groups_file="${tmpdir}/groups.tsv"
top_file="${tmpdir}/top.tsv"
: >"${groups_file}"
: >"${top_file}"

echo "Redis keyspace summary"
echo "Host container: ${REDIS_CONTAINER}"
echo "Pattern: ${REDIS_KEY_PATTERN}"
case "${REDIS_KEY_PATTERN}" in
  *[\*\?\[]*)
    ;;
  *)
    echo "Pattern has no Redis glob wildcard; it only matches a literal key named '${REDIS_KEY_PATTERN}'." >&2
    echo "Use '${REDIS_KEY_PATTERN}*' to match keys with that prefix." >&2
    ;;
esac
echo ""
docker_redis_cli INFO keyspace | sed -n '/^# Keyspace/,$p' | sed '/^$/d' || true

databases="$(list_databases)"
if [ -z "${databases}" ]; then
  echo ""
  echo "No Redis databases with keys found."
  exit 0
fi

echo ""
echo "Scanning keys. This can take a while on large databases."

for db in ${databases}; do
  scanned=0

  while IFS=$'\t' read -r record_type field1 field2 field3 field4 field5 field6; do
    case "${record_type}" in
      G)
        scanned=$((scanned + 1))
        group="$(printf "%s\n" "${field2}" | key_group)"
        printf "%s\t%s\t%s\t%s\t%s\n" "${field1}" "${group}" "${field3:-0}" "${field4}" "${field5}" >>"${groups_file}"
        ;;
      T)
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "${field1:-0}" "${field2}" "${field3}" "${field4}" "${field5}" "${field6}" >>"${top_file}"
        ;;
    esac
  done < <(scan_database "${db}")

  echo "Scanned db${db}: ${scanned} keys"
done

if [ ! -s "${groups_file}" ]; then
  echo ""
  echo "No keys matched pattern: ${REDIS_KEY_PATTERN}"
  exit 0
fi

echo ""
echo "Largest key groups"
awk -F '\t' '
  {
    id = "db" $1 ":" $2;
    count[id] += 1;
    bytes[id] += $3;
    type_key = id SUBSEP $5;
    types[type_key] += 1;
    if (!(type_key in seen_type)) {
      seen_type[type_key] = 1;
      type_names[id] = type_names[id] (type_names[id] == "" ? "" : SUBSEP) $5;
    }
    if ($4 == -1) no_ttl[id] += 1;
    else if ($4 >= 0) {
      expiring[id] += 1;
      if (!(id in min_ttl) || $4 < min_ttl[id]) min_ttl[id] = $4;
      if (!(id in max_ttl) || $4 > max_ttl[id]) max_ttl[id] = $4;
    }
  }
  END {
    for (id in count) {
      type_summary = "";
      split(type_names[id], names, SUBSEP);
      for (i in names) {
        type = names[i];
        type_summary = type_summary (type_summary == "" ? "" : ",") type ":" types[id SUBSEP type];
      }
      printf "%d\t%d\t%d\t%d\t%s\t%s\t%s\n",
        bytes[id], count[id], no_ttl[id] + 0, expiring[id] + 0,
        (id in min_ttl ? min_ttl[id] : ""), (id in max_ttl ? max_ttl[id] : ""), id "\t" type_summary;
    }
  }' "${groups_file}" \
  | sort -rn -k1,1 -k2,2 \
  | awk -F '\t' '
    BEGIN {
      printf "%-42s %10s %8s %8s %8s %10s %10s %s\n", "group", "memory", "keys", "noTTL", "expires", "minTTL", "maxTTL", "types";
    }
    {
      cmd = "awk -v bytes=" $1 " '\''BEGIN { split(\"B KiB MiB GiB TiB\", units, \" \"); value = bytes + 0; unit = 1; while (value >= 1024 && unit < 5) { value /= 1024; unit += 1 } if (unit == 1 || value >= 10) printf \"%.0f %s\", value, units[unit]; else printf \"%.1f %s\", value, units[unit]; }'\''";
      cmd | getline formatted;
      close(cmd);

      min_ttl = $5 == "" ? "" : $5 "s";
      max_ttl = $6 == "" ? "" : $6 "s";
      printf "%-42s %10s %8d %8d %8d %10s %10s %s\n", $7, formatted, $2, $3, $4, min_ttl, max_ttl, $8;
    }'

echo ""
echo "Largest individual keys"
sort -rn -k1,1 "${top_file}" \
  | head -n "${REDIS_TOP_KEYS}" \
  | while IFS=$'\t' read -r memory db type metric ttl key; do
      printf "%10s  db%-3s %-7s len=%-10s ttl=%-8s %s\n" \
        "$(format_bytes "${memory}")" \
        "${db}" \
        "${type}" \
        "${metric}" \
        "$(format_ttl "${ttl}")" \
        "${key}"
    done

if [ "${REDIS_WARN_NO_TTL}" = "1" ]; then
  no_ttl_count="$(awk -F '\t' '$4 == -1 { count += 1 } END { print count + 0 }' "${groups_file}")"
  if [ "${no_ttl_count}" -gt 0 ]; then
    echo ""
    echo "WARNING: ${no_ttl_count} matched keys have no TTL. Persistent keys in purge-managed collections are the first place to investigate."
  fi
fi
REMOTE
