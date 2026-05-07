#!/usr/bin/env bash
set -euo pipefail

# Install MongoDB 7 on a target host using Docker (localhost-only, with persistent data volume)
# Modeled on server-tooling/redis/install-redis.sh
#
# Usage: ./install-mongo.sh [HOST]
#   HOST: Target hostname (default: sky)
#
# After install, run the seed:
#   ssh sky 'cd /home/mwagstaff/dev/kidventures && npm run seed -w services/api'

HOST="${1:-sky}"
MONGO_VERSION="${MONGO_VERSION:-7}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DATA_DIR="/var/lib/mongo-data"
MONGO_CONTAINER="mongo-kidventures"

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
ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- "${MONGO_VERSION}" "${MONGO_PORT}" "${MONGO_DATA_DIR}" "${MONGO_CONTAINER}" <<'REMOTE'
set -euo pipefail

MONGO_VERSION="${1}"
MONGO_PORT="${2}"
MONGO_DATA_DIR="${3}"
MONGO_CONTAINER="${4}"

# Create data and config directories
sudo mkdir -p "${MONGO_DATA_DIR}"
sudo chown -R 999:999 "${MONGO_DATA_DIR}"   # MongoDB user UID in official image

# Stop and remove existing container if present
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"; then
  echo "Stopping existing container ${MONGO_CONTAINER}..."
  sudo docker stop "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
  sudo docker rm "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
fi

# Write mongod config
MONGO_CONF="${MONGO_DATA_DIR}/mongod.conf"
sudo tee "${MONGO_CONF}" > /dev/null <<CONF
# network
net:
  port: ${MONGO_PORT}
  bindIp: 127.0.0.1      # localhost only — Caddy/app on same host

# storage
storage:
  dbPath: /data/db

# process
processManagement:
  timeZoneInfo: /usr/share/zoneinfo

# replica set — required for transactions and change streams
replication:
  replSetName: "rs0"
CONF

sudo chown 999:999 "${MONGO_CONF}"

echo "Starting MongoDB container..."
sudo docker run -d \
  --name "${MONGO_CONTAINER}" \
  --restart unless-stopped \
  --network host \
  -v "${MONGO_DATA_DIR}:/data/db" \
  -v "${MONGO_CONF}:/etc/mongod.conf:ro" \
  mongo:"${MONGO_VERSION}" \
  mongod --config /etc/mongod.conf

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
echo "  - Replica set: rs0 (single node — enables transactions)"
echo "  - Restart   : unless-stopped (survives reboots)"
echo ""
echo "🔧 Management commands:"
echo "  Shell   :  ssh ${HOST} 'sudo docker exec -it ${MONGO_CONTAINER} mongosh'"
echo "  Logs    :  ssh ${HOST} 'sudo docker logs -f ${MONGO_CONTAINER}'"
echo "  Stop    :  ssh ${HOST} 'sudo docker stop ${MONGO_CONTAINER}'"
echo "  Start   :  ssh ${HOST} 'sudo docker start ${MONGO_CONTAINER}'"
echo ""
echo "💾 Backups — add to cron on ${HOST}:"
echo "  0 3 * * * sudo docker exec ${MONGO_CONTAINER} mongodump --archive --gzip --db kidventures | gzip > /backups/kidventures/\$(date +\\%Y\\%m\\%d).gz"
echo ""
echo "📥 Next step — run the seed:"
echo "  ssh ${HOST} 'cd ~/dev/kidventures && MONGODB_URI=mongodb://localhost:${MONGO_PORT}/kidventures npm run seed -w services/api'"
