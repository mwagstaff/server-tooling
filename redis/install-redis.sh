#!/usr/bin/env bash
set -euo pipefail

# Install Redis on a target host using Docker
# Usage: ./install-redis.sh [HOST]
#   HOST: Target hostname (default: ocl)

HOST="${1:-ocl}"
REDIS_VERSION="${REDIS_VERSION:-7-alpine}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DATA_DIR="/var/lib/redis-data"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

log "Installing Redis on ${HOST}"

# Check if host is reachable
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_OPTS[@]}" "${HOST}" "exit" 2>/dev/null; then
  die "Cannot connect to ${HOST}"
fi

log "Checking Docker installation"
if ! ssh "${SSH_OPTS[@]}" "${HOST}" "command -v docker >/dev/null 2>&1"; then
  die "Docker is not installed on ${HOST}. Please install Docker first."
fi

log "Ensuring Docker starts on boot"
ssh "${SSH_OPTS[@]}" "${HOST}" "sudo systemctl enable docker >/dev/null 2>&1 || true"

log "Setting up Redis container"
ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- "${REDIS_VERSION}" "${REDIS_PORT}" "${REDIS_DATA_DIR}" <<'EOF'
set -e

REDIS_VERSION="${1}"
REDIS_PORT="${2}"
REDIS_DATA_DIR="${3}"

# Create data directory
sudo mkdir -p "${REDIS_DATA_DIR}"
sudo chown -R 999:999 "${REDIS_DATA_DIR}"  # Redis user in official image

# Stop and remove existing Redis container if present
if sudo docker ps -a | grep -q redis-server; then
  echo "Stopping existing Redis container..."
  sudo docker stop redis-server >/dev/null 2>&1 || true
  sudo docker rm redis-server >/dev/null 2>&1 || true
fi

# Create Redis configuration
REDIS_CONF="${REDIS_DATA_DIR}/redis.conf"
sudo tee "${REDIS_CONF}" > /dev/null <<REDISCONF
# Network
bind 127.0.0.1
port ${REDIS_PORT}
protected-mode yes

# Persistence (RDB snapshots)
save 900 1
save 300 10
save 60 10000
dir /data
dbfilename dump.rdb

# Logging
loglevel notice

# Memory
maxmemory 256mb
maxmemory-policy allkeys-lru

# Performance
tcp-backlog 511
timeout 0
tcp-keepalive 300
REDISCONF

sudo chown 999:999 "${REDIS_CONF}"

# Run Redis container
echo "Starting Redis container..."
sudo docker run -d \
  --name redis-server \
  --restart unless-stopped \
  --network host \
  -v "${REDIS_DATA_DIR}:/data" \
  -v "${REDIS_CONF}:/usr/local/etc/redis/redis.conf" \
  redis:"${REDIS_VERSION}" \
  redis-server /usr/local/etc/redis/redis.conf

# Wait for Redis to be ready
echo "Waiting for Redis to be ready..."
for i in {1..30}; do
  if sudo docker exec redis-server redis-cli ping >/dev/null 2>&1; then
    echo "Redis is ready!"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Redis failed to start" >&2
    sudo docker logs redis-server
    exit 1
  fi
  sleep 1
done

echo "Redis installation complete!"
EOF

log "Verification"
ssh "${SSH_OPTS[@]}" "${HOST}" bash <<'EOF'
echo ""
echo "Docker service status:"
if systemctl is-enabled docker >/dev/null 2>&1; then
  echo "✅ Docker is enabled to start on boot"
else
  echo "⚠️  Docker may not start on boot"
fi

echo ""
echo "Container status:"
sudo docker ps | grep redis-server || echo "WARNING: Container not running"

echo ""
echo "Container restart policy:"
sudo docker inspect redis-server --format='{{.HostConfig.RestartPolicy.Name}}' || true

echo ""
echo "Redis info:"
sudo docker exec redis-server redis-cli INFO server | grep -E "redis_version|os|arch|process_id" || true

echo ""
echo "Redis persistence config:"
sudo docker exec redis-server redis-cli CONFIG GET "save" || true
sudo docker exec redis-server redis-cli CONFIG GET "dir" || true
sudo docker exec redis-server redis-cli CONFIG GET "dbfilename" || true

echo ""
echo "Data directory:"
ls -lh /var/lib/redis-data/ 2>/dev/null || echo "Data directory empty (no snapshots yet)"

echo ""
echo "Testing connection:"
if sudo docker exec redis-server redis-cli PING | grep -q "PONG"; then
  echo "✅ Redis is responding to PING"
else
  echo "❌ Redis is not responding"
  exit 1
fi
EOF

log "Done!"
echo ""
echo "✅ Redis is now running on ${HOST}:${REDIS_PORT} (localhost only)"
echo ""
echo "📦 Configuration:"
echo "  - Container: redis-server"
echo "  - Restart policy: unless-stopped (survives reboots)"
echo "  - Data directory: ${REDIS_DATA_DIR}"
echo "  - Persistence: RDB snapshots enabled"
echo "  - Docker service: enabled on boot"
echo ""
echo "🔧 Management commands:"
echo "  Connect:     ssh ${HOST} 'sudo docker exec -it redis-server redis-cli'"
echo "  View logs:   ssh ${HOST} 'sudo docker logs -f redis-server'"
echo "  Stop:        ssh ${HOST} 'sudo docker stop redis-server'"
echo "  Start:       ssh ${HOST} 'sudo docker start redis-server'"
echo "  Restart:     ssh ${HOST} 'sudo docker restart redis-server'"
echo ""
echo "💾 Data persistence:"
echo "  Data is automatically saved to disk and will be restored on restart/reboot"
echo "  Snapshot location: ${REDIS_DATA_DIR}/dump.rdb"
