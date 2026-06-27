#!/usr/bin/env bash
set -euo pipefail

# Install MongoDB 7 on a target host using Docker (localhost-only, with persistent data volume)
# Modeled on server-tooling/redis/install-redis.sh
#
# Usage: ./install-mongo.sh [HOST]
#   HOST: Target hostname (default: sky)
#
# After install, run the seed:
#   ssh sky 'cd /home/mwagstaff/dev/kidsplorers && npm run seed -w services/api'

HOST="${1:-sky}"
MONGO_VERSION="${MONGO_VERSION:-7}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DATA_DIR="/var/lib/mongo-data"
MONGO_CONTAINER="mongo-kidsplorers"
# WiredTiger cache cap (GB). MongoDB defaults to ~50% of host RAM, which on a
# small shared box lets Mongo balloon until the kernel OOM-kills it. Cap it so
# Mongo leaves headroom for the other co-tenant services.
MONGO_CACHE_SIZE_GB="${MONGO_CACHE_SIZE_GB:-1}"
# Set RECREATE=1 to force a stop/rm/run (e.g. to pick up a new image tag).
# Default 0: an existing container is restarted in place only when config changes.
RECREATE="${RECREATE:-0}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

log()  { printf "\n==> %s\n" "$*"; }
die()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
ok()   { printf "  ✅ %s\n" "$*"; }
warn() { printf "  ⚠️  %s\n" "$*"; }

log "Installing MongoDB ${MONGO_VERSION} on ${HOST}"

# Check SSH connectivity
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_OPTS[@]}" "${HOST}" "exit" 2>/dev/null; then
  die "Cannot connect to ${HOST}"
fi

log "Checking Docker"
if ! ssh "${SSH_OPTS[@]}" "${HOST}" "command -v docker >/dev/null 2>&1"; then
  die "Docker is not installed on ${HOST}. Please install Docker first."
fi

log "Ensuring Docker starts on boot"
ssh "${SSH_OPTS[@]}" "${HOST}" "sudo systemctl enable docker >/dev/null 2>&1 || true"

log "Setting up MongoDB container"
ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- "${MONGO_VERSION}" "${MONGO_PORT}" "${MONGO_DATA_DIR}" "${MONGO_CONTAINER}" "${MONGO_CACHE_SIZE_GB}" "${RECREATE}" <<'REMOTE'
set -euo pipefail

MONGO_VERSION="${1}"
MONGO_PORT="${2}"
MONGO_DATA_DIR="${3}"
MONGO_CONTAINER="${4}"
MONGO_CACHE_SIZE_GB="${5}"
RECREATE="${6}"

MONGO_CONF="${MONGO_DATA_DIR}/mongod.conf"

# Ensure data directory exists.
sudo mkdir -p "${MONGO_DATA_DIR}"

# Build the desired config in a temp file so we can compare it against what's
# already on disk and only act when something actually changed.
DESIRED_CONF="$(mktemp)"
cat > "${DESIRED_CONF}" <<CONF
# network
net:
  port: ${MONGO_PORT}
  bindIp: 127.0.0.1      # localhost only — Caddy/app on same host

# storage
storage:
  dbPath: /data/db
  wiredTiger:
    engineConfig:
      cacheSizeGB: ${MONGO_CACHE_SIZE_GB}   # cap cache to leave host RAM headroom

# process
processManagement:
  timeZoneInfo: /usr/share/zoneinfo

# replica set — required for transactions and change streams
replication:
  replSetName: "rs0"
CONF

# Write the config only if it differs (idempotent), tracking whether it changed.
CONFIG_CHANGED=1
if sudo test -f "${MONGO_CONF}" && sudo cmp -s "${DESIRED_CONF}" "${MONGO_CONF}"; then
  CONFIG_CHANGED=0
  echo "mongod.conf already up to date"
else
  sudo cp "${DESIRED_CONF}" "${MONGO_CONF}"
  sudo chown 999:999 "${MONGO_CONF}"   # MongoDB user UID in official image
  echo "mongod.conf written (cacheSizeGB=${MONGO_CACHE_SIZE_GB})"
fi
rm -f "${DESIRED_CONF}"

# Determine current container state.
CONTAINER_EXISTS=0
CONTAINER_RUNNING=0
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"; then
  CONTAINER_EXISTS=1
  if sudo docker ps --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"; then
    CONTAINER_RUNNING=1
  fi
fi

# Force a full recreate when requested (e.g. to pick up a new image tag).
if [ "${RECREATE}" = "1" ] && [ "${CONTAINER_EXISTS}" -eq 1 ]; then
  echo "RECREATE=1 — removing existing container ${MONGO_CONTAINER}..."
  sudo docker stop "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
  sudo docker rm "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
  CONTAINER_EXISTS=0
  CONTAINER_RUNNING=0
fi

if [ "${CONTAINER_EXISTS}" -eq 0 ]; then
  echo "Creating MongoDB container..."
  sudo chown -R 999:999 "${MONGO_DATA_DIR}"   # fresh data dir: ensure ownership
  sudo docker run -d \
    --name "${MONGO_CONTAINER}" \
    --restart unless-stopped \
    --network host \
    -v "${MONGO_DATA_DIR}:/data/db" \
    -v "${MONGO_CONF}:/etc/mongod.conf:ro" \
    mongo:"${MONGO_VERSION}" \
    mongod --config /etc/mongod.conf
elif [ "${CONFIG_CHANGED}" -eq 1 ]; then
  echo "Config changed — restarting container to apply (bind-mounted config)..."
  sudo docker restart "${MONGO_CONTAINER}" >/dev/null
elif [ "${CONTAINER_RUNNING}" -eq 0 ]; then
  echo "Container stopped — starting..."
  sudo docker start "${MONGO_CONTAINER}" >/dev/null
else
  echo "Container already running with current config — no restart needed"
fi

# Wait for MongoDB to accept connections
echo "Waiting for MongoDB to be ready..."
for i in $(seq 1 30); do
  if sudo docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
    echo "MongoDB is ready!"
    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "ERROR: MongoDB failed to start" >&2
    sudo docker logs "${MONGO_CONTAINER}" | tail -20
    exit 1
  fi
  sleep 2
done

# Initialise the replica set (idempotent — safe to re-run)
echo "Initialising replica set rs0..."
sudo docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval '
  try {
    rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "127.0.0.1:'"${MONGO_PORT}"'" }] });
    print("Replica set initiated");
  } catch (e) {
    if (e.codeName === "AlreadyInitialized") { print("Replica set already initialised"); }
    else { throw e; }
  }
'

echo "MongoDB installation complete!"
REMOTE

log "Verification"
ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- "${MONGO_CONTAINER}" <<'VERIFY'
set -euo pipefail
MONGO_CONTAINER="${1}"

echo ""
echo "Container status:"
sudo docker ps | grep "${MONGO_CONTAINER}" && printf "  ✅ Container running\n" || printf "  ⚠️  Container NOT running\n"

echo ""
echo "Restart policy:"
sudo docker inspect "${MONGO_CONTAINER}" --format='{{.HostConfig.RestartPolicy.Name}}' || true

echo ""
echo "MongoDB version:"
sudo docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'db.version()' 2>/dev/null || true

echo ""
echo "Replica set status:"
sudo docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'rs.status().ok' 2>/dev/null || true

echo ""
echo "WiredTiger cache cap:"
sudo docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval '
  const gb = db.serverStatus().wiredTiger.cache["maximum bytes configured"] / (1024*1024*1024);
  print("  " + gb.toFixed(2) + " GB");
' 2>/dev/null || true

echo ""
echo "Ping:"
if sudo docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q "1"; then
  printf "  ✅ MongoDB is responding\n"
else
  printf "  ❌ MongoDB is not responding\n"
  exit 1
fi
VERIFY

log "Done!"
echo ""
echo "✅ MongoDB is now running on ${HOST}:${MONGO_PORT} (localhost only)"
echo ""
echo "📦 Configuration:"
echo "  - Container : ${MONGO_CONTAINER}"
echo "  - Image     : mongo:${MONGO_VERSION}"
echo "  - Port      : ${MONGO_PORT} (localhost only)"
echo "  - Data dir  : ${MONGO_DATA_DIR}"
echo "  - Cache cap : ${MONGO_CACHE_SIZE_GB} GB (WiredTiger)"
echo "  - Replica set: rs0 (single node — enables transactions)"
echo "  - Restart   : unless-stopped (survives reboots)"
echo ""
echo "♻️  Re-running this script is safe: it updates mongod.conf and restarts"
echo "    only when the config changed. Override the cache cap with"
echo "    MONGO_CACHE_SIZE_GB=2 ./install-mongo.sh, or force a full recreate"
echo "    (e.g. for an image bump) with RECREATE=1 ./install-mongo.sh"
echo ""
echo "🔧 Management commands:"
echo "  Shell   :  ssh ${HOST} 'sudo docker exec -it ${MONGO_CONTAINER} mongosh'"
echo "  Logs    :  ssh ${HOST} 'sudo docker logs -f ${MONGO_CONTAINER}'"
echo "  Stop    :  ssh ${HOST} 'sudo docker stop ${MONGO_CONTAINER}'"
echo "  Start   :  ssh ${HOST} 'sudo docker start ${MONGO_CONTAINER}'"
echo ""
echo "💾 Backups — add to cron on ${HOST}:"
echo "  0 3 * * * sudo docker exec ${MONGO_CONTAINER} mongodump --archive --gzip --db kidsplorers | gzip > /backups/kidsplorers/\$(date +\\%Y\\%m\\%d).gz"
echo ""
echo "📥 Next step — run the seed:"
echo "  ssh ${HOST} 'cd ~/dev/kidsplorers && MONGODB_URI=mongodb://localhost:${MONGO_PORT}/kidsplorers npm run seed -w services/api'"
