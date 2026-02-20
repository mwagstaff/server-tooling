#!/usr/bin/env bash
set -euo pipefail

# Install Redis locally on macOS using Homebrew
# Usage: ./install-redis-local.sh

REDIS_PORT="${REDIS_PORT:-6379}"

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

log "Installing Redis locally on macOS"

# Check if Homebrew is installed
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew is not installed. Install it from https://brew.sh"
fi

# Check if Redis is already installed
if brew list redis >/dev/null 2>&1; then
  log "Redis is already installed, checking version"
  CURRENT_VERSION=$(redis-server --version | head -n1)
  echo "Current version: ${CURRENT_VERSION}"

  read -p "Reinstall/upgrade Redis? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Skipping Redis installation"
  else
    log "Upgrading Redis"
    brew upgrade redis || brew reinstall redis
  fi
else
  log "Installing Redis via Homebrew"
  brew install redis
fi

# Get Homebrew prefix (handles both Intel and Apple Silicon)
BREW_PREFIX=$(brew --prefix)
REDIS_CONF="${BREW_PREFIX}/etc/redis.conf"
REDIS_DATA_DIR="${BREW_PREFIX}/var/db/redis"

log "Configuring Redis to match Oracle server settings"

# Backup existing config if present
if [[ -f "$REDIS_CONF" ]]; then
  cp "$REDIS_CONF" "${REDIS_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
  echo "Backed up existing config"
fi

# Create Redis configuration matching the Oracle server
cat > "$REDIS_CONF" <<EOF
# Network
bind 127.0.0.1
port ${REDIS_PORT}
protected-mode yes

# Persistence (RDB snapshots)
save 900 1
save 300 10
save 60 10000
dir ${REDIS_DATA_DIR}
dbfilename dump.rdb

# Logging
loglevel notice
logfile ${BREW_PREFIX}/var/log/redis.log

# Memory
maxmemory 256mb
maxmemory-policy allkeys-lru

# Performance
tcp-backlog 511
timeout 0
tcp-keepalive 300
EOF

# Ensure data directory exists
mkdir -p "$REDIS_DATA_DIR"
mkdir -p "${BREW_PREFIX}/var/log"

log "Starting Redis service"

# Stop if already running
brew services stop redis >/dev/null 2>&1 || true

# Start Redis as a service (will auto-start on login)
brew services start redis

# Wait for Redis to be ready
log "Waiting for Redis to be ready"
for i in {1..30}; do
  if redis-cli ping >/dev/null 2>&1; then
    echo "Redis is ready!"
    break
  fi
  if [ "$i" -eq 30 ]; then
    die "Redis failed to start. Check logs: tail -f ${BREW_PREFIX}/var/log/redis.log"
  fi
  sleep 1
done

log "Verification"
echo ""
echo "Redis version:"
redis-server --version | head -n1

echo ""
echo "Service status:"
brew services list | grep redis

echo ""
echo "Redis info:"
redis-cli INFO server | grep -E "redis_version|os|arch|process_id|config_file"

echo ""
echo "Redis config:"
redis-cli CONFIG GET "bind"
redis-cli CONFIG GET "port"
redis-cli CONFIG GET "save"
redis-cli CONFIG GET "dir"

echo ""
echo "Data directory:"
ls -lh "$REDIS_DATA_DIR" 2>/dev/null || echo "Data directory empty (no snapshots yet)"

echo ""
echo "Testing connection:"
if redis-cli PING | grep -q "PONG"; then
  echo "✅ Redis is responding to PING"
else
  echo "❌ Redis is not responding"
  exit 1
fi

log "Done!"
echo ""
echo "✅ Redis is now running locally on 127.0.0.1:${REDIS_PORT}"
echo ""
echo "📦 Configuration:"
echo "  - Service: managed by Homebrew services"
echo "  - Config file: ${REDIS_CONF}"
echo "  - Data directory: ${REDIS_DATA_DIR}"
echo "  - Log file: ${BREW_PREFIX}/var/log/redis.log"
echo "  - Persistence: RDB snapshots enabled (matches Oracle server)"
echo "  - Auto-start: enabled (starts on login)"
echo ""
echo "🔧 Management commands:"
echo "  Connect:     redis-cli"
echo "  View logs:   tail -f ${BREW_PREFIX}/var/log/redis.log"
echo "  Stop:        brew services stop redis"
echo "  Start:       brew services start redis"
echo "  Restart:     brew services restart redis"
echo "  Info:        brew services info redis"
echo ""
echo "💾 Data persistence:"
echo "  Data is automatically saved to disk and will be restored on restart"
echo "  Snapshot location: ${REDIS_DATA_DIR}/dump.rdb"
echo ""
echo "🔄 Configuration matches your Oracle Cloud server for consistent dev/prod behavior"
