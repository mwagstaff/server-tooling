#!/usr/bin/env bash
set -euo pipefail

# Take an ad hoc MongoDB backup from a remote Docker host and copy it locally.
#
# Usage:
#   ./adhoc-backup.sh [HOST] [DEST_DIR]
#
# Defaults:
#   HOST     sky
#   DEST_DIR current directory
#
# Environment:
#   MONGO_CONTAINER   MongoDB container name (default: mongo-kidsplorers)
#   MONGODUMP_URI     URI used when mongodump runs on the host (default: localhost)
#   MONGODB_TOOLS_VERSION
#                     Database Tools version to auto-download if needed
#                     (default: 100.17.0)
#   MONGODB_TOOLS_PLATFORM
#                     Override auto-detected tools platform, e.g.
#                     ubuntu2204-x86_64
#   REMOTE_BACKUP_DIR Remote temp directory (default: /tmp/mongo-adhoc-backups)
#   KEEP_REMOTE       Set to 1 to leave the archive on the remote host

HOST="${1:-sky}"
DEST_DIR="${2:-.}"

MONGO_CONTAINER="${MONGO_CONTAINER:-mongo-kidsplorers}"
MONGODUMP_URI="${MONGODUMP_URI:-mongodb://127.0.0.1:27017/?directConnection=true}"
MONGODB_TOOLS_VERSION="${MONGODB_TOOLS_VERSION:-100.17.0}"
MONGODB_TOOLS_PLATFORM="${MONGODB_TOOLS_PLATFORM:-}"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/tmp/mongo-adhoc-backups}"
KEEP_REMOTE="${KEEP_REMOTE:-0}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

if [ "$#" -gt 2 ]; then
  die "Usage: $0 [HOST] [DEST_DIR]"
fi

mkdir -p "${DEST_DIR}"
DEST_DIR="$(cd "${DEST_DIR}" && pwd -P)"

SAFE_HOST="$(printf "%s" "${HOST}" | tr -c "A-Za-z0-9._-" "_")"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILENAME="${TIMESTAMP}_${SAFE_HOST}_mongo.archive.gz"
REMOTE_FILE="${REMOTE_BACKUP_DIR}/${FILENAME}"
LOCAL_FILE="${DEST_DIR}/${FILENAME}"

log "Checking SSH connectivity to ${HOST}"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_OPTS[@]}" "${HOST}" "exit" 2>/dev/null; then
  die "Cannot connect to ${HOST}"
fi

log "Creating MongoDB archive on ${HOST}"
ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- \
  "${MONGO_CONTAINER}" \
  "${REMOTE_BACKUP_DIR}" \
  "${REMOTE_FILE}" \
  "${MONGODUMP_URI}" \
  "${MONGODB_TOOLS_VERSION}" \
  "${MONGODB_TOOLS_PLATFORM}" <<'REMOTE'
set -euo pipefail

MONGO_CONTAINER="${1}"
REMOTE_BACKUP_DIR="${2}"
REMOTE_FILE="${3}"
MONGODUMP_URI="${4}"
MONGODB_TOOLS_VERSION="${5}"
MONGODB_TOOLS_PLATFORM="${6:-}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or not on PATH" >&2
  exit 1
fi

if ! sudo docker ps --format '{{.Names}}' | grep -qx "${MONGO_CONTAINER}"; then
  echo "MongoDB container is not running: ${MONGO_CONTAINER}" >&2
  exit 1
fi

mkdir -p "${REMOTE_BACKUP_DIR}"
TMP_FILE="${REMOTE_FILE}.tmp"
rm -f "${TMP_FILE}"

detect_tools_platform() {
  local arch os_id os_version os_major

  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      echo "Unsupported CPU architecture for MongoDB Database Tools: $(uname -m)" >&2
      return 1
      ;;
  esac

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
  else
    os_id=""
    os_version=""
  fi

  os_major="${os_version%%.*}"
  case "${os_id}:${os_major}:${arch}" in
    ubuntu:16:*) printf "ubuntu1604-%s\n" "${arch}" ;;
    ubuntu:18:*) printf "ubuntu1804-%s\n" "${arch}" ;;
    ubuntu:20:*) printf "ubuntu2004-%s\n" "${arch}" ;;
    ubuntu:22:*) printf "ubuntu2204-%s\n" "${arch}" ;;
    ubuntu:24:*) printf "ubuntu2404-%s\n" "${arch}" ;;
    debian:9:x86_64) printf "debian92-x86_64\n" ;;
    debian:10:x86_64) printf "debian10-x86_64\n" ;;
    debian:11:x86_64) printf "debian11-x86_64\n" ;;
    debian:12:x86_64) printf "debian12-x86_64\n" ;;
    *)
      # The target host is expected to be Ubuntu; keep a practical fallback.
      printf "ubuntu2204-%s\n" "${arch}"
      ;;
  esac
}

download() {
  local url="${1}"
  local output="${2}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${output}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${output}" "${url}"
  else
    echo "Neither curl nor wget is available to download MongoDB Database Tools" >&2
    return 1
  fi
}

ensure_mongodump() {
  local platform tools_dir tmp_dir archive url

  if command -v mongodump >/dev/null 2>&1; then
    command -v mongodump
    return 0
  fi

  platform="${MONGODB_TOOLS_PLATFORM:-$(detect_tools_platform)}"
  tools_dir="${REMOTE_BACKUP_DIR}/.tools/mongodb-database-tools-${platform}-${MONGODB_TOOLS_VERSION}"

  if [ ! -x "${tools_dir}/bin/mongodump" ]; then
    echo "mongodump not found; downloading MongoDB Database Tools ${MONGODB_TOOLS_VERSION} (${platform})..." >&2

    tmp_dir="${tools_dir}.tmp"
    archive="${tmp_dir}.tgz"
    url="https://fastdl.mongodb.org/tools/db/mongodb-database-tools-${platform}-${MONGODB_TOOLS_VERSION}.tgz"

    rm -rf "${tmp_dir}" "${archive}"
    mkdir -p "${tmp_dir}"
    download "${url}" "${archive}"
    tar -xzf "${archive}" -C "${tmp_dir}" --strip-components=1
    rm -f "${archive}"

    rm -rf "${tools_dir}"
    mv "${tmp_dir}" "${tools_dir}"
  fi

  printf "%s\n" "${tools_dir}/bin/mongodump"
}

# No --db or --collection flags: this captures all databases and collections.
if sudo docker exec "${MONGO_CONTAINER}" command -v mongodump >/dev/null 2>&1; then
  sudo docker exec "${MONGO_CONTAINER}" mongodump --archive --gzip > "${TMP_FILE}"
else
  MONGODUMP_BIN="$(ensure_mongodump)"
  "${MONGODUMP_BIN}" --uri="${MONGODUMP_URI}" --archive --gzip > "${TMP_FILE}"
fi

mv "${TMP_FILE}" "${REMOTE_FILE}"

printf "Remote archive: %s (%s)\n" "${REMOTE_FILE}" "$(du -h "${REMOTE_FILE}" | cut -f1)"
REMOTE

log "Copying backup to ${LOCAL_FILE}"
scp "${SSH_OPTS[@]}" "${HOST}:${REMOTE_FILE}" "${LOCAL_FILE}"

if [ "${KEEP_REMOTE}" = "1" ]; then
  log "Leaving remote archive in place"
  printf "%s\n" "${REMOTE_FILE}"
else
  log "Removing remote temporary archive"
  ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- "${REMOTE_FILE}" <<'REMOTE'
set -euo pipefail
rm -f "${1}"
REMOTE
fi

log "Backup complete"
printf "Local archive: %s (%s)\n" "${LOCAL_FILE}" "$(du -h "${LOCAL_FILE}" | cut -f1)"
