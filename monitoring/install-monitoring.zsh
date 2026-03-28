#!/usr/bin/env zsh
set -euo pipefail

TARGET_HOST="${1:-${TARGET_HOST:-ocl}}"
# Note: tilde expansion doesn't work in variable assignments passed to remote shell
# Use explicit \$HOME (escaped so it evaluates on remote) or absolute path
REMOTE_DIR="${REMOTE_DIR:-\$HOME/monitoring}"
GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-3001}"
PROM_HOST_PORT="${PROM_HOST_PORT:-9090}"
GRAFANA_ROOT_URL="${GRAFANA_ROOT_URL:-https://api.skynolimit.dev/grafana}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-api.skynolimit.dev}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_BW_ITEM_NAME="${GRAFANA_BW_ITEM_NAME:-GRAFANA_LOGIN}"
BW_FOLDER_ID="${BW_FOLDER_ID:-7a5cbc24-a5c4-4d07-bbf3-b3f600e24660}"
BW_SESSION_CACHE_ENABLED="${BW_SESSION_CACHE_ENABLED:-1}"
BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"

PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:latest}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:latest}"

have_valid_bw_session() {
  [[ -n "${BW_SESSION:-}" ]] || return 1
  bw --nointeraction --session "$BW_SESSION" list items --folderid "$BW_FOLDER_ID" >/dev/null 2>&1
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
  local output status attempt

  for attempt in 1 2; do
    output="$(bw --nointeraction --session "$BW_SESSION" "$@" 2>&1)" && {
      printf '%s\n' "$output"
      return 0
    }
    status=$?

    if [[ "$attempt" -eq 1 ]] && bw_output_indicates_session_issue "$output"; then
      echo "==> Bitwarden session became invalid; unlocking again..."
      clear_cached_bw_session
      unset BW_SESSION
      ensure_bw_session
      continue
    fi

    printf '%s\n' "$output" >&2
    return "$status"
  done

  return 1
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

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to read Bitwarden items" >&2
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

load_grafana_password() {
  if [[ -n "${GRAFANA_PASSWORD:-}" ]]; then
    GRAFANA_PASSWORD_SOURCE="environment"
    return
  fi

  ensure_bw_session
  echo "==> Refreshing Bitwarden vault data..."
  run_bw_with_session sync >/dev/null

  GRAFANA_PASSWORD="$(
    run_bw_with_session list items --search "$GRAFANA_BW_ITEM_NAME" 2>/dev/null \
      | jq -r --arg name "$GRAFANA_BW_ITEM_NAME" '.[] | select(.name == $name) | .login.password // empty' \
      | head -n 1
  )"

  if [[ -z "$GRAFANA_PASSWORD" ]]; then
    echo "Error: Bitwarden item '$GRAFANA_BW_ITEM_NAME' was not found or has no password" >&2
    exit 1
  fi

  GRAFANA_PASSWORD_SOURCE="Bitwarden item '$GRAFANA_BW_ITEM_NAME'"
}

load_grafana_password
GRAFANA_PASSWORD_B64="$(printf '%s' "$GRAFANA_PASSWORD" | base64 | tr -d '\n')"

echo "==> Installing Prometheus + Grafana on: ${TARGET_HOST}"
echo "==> Remote dir: ${REMOTE_DIR}"
echo "==> Grafana port: ${GRAFANA_HOST_PORT} -> container 3000"
echo "==> Grafana root URL: ${GRAFANA_ROOT_URL}"
echo "==> Grafana domain: ${GRAFANA_DOMAIN}"
echo "==> Grafana admin user: ${GRAFANA_USER}"
echo "==> Grafana admin password source: ${GRAFANA_PASSWORD_SOURCE}"
echo "==> Prometheus port: ${PROM_HOST_PORT} -> container 9090"
echo

ssh -o BatchMode=yes "${TARGET_HOST}" "bash -s" <<EOF
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

REMOTE_DIR="${REMOTE_DIR}"
GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT}"
PROM_HOST_PORT="${PROM_HOST_PORT}"
PROM_IMAGE="${PROM_IMAGE}"
GRAFANA_IMAGE="${GRAFANA_IMAGE}"
GRAFANA_ROOT_URL="${GRAFANA_ROOT_URL}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN}"
GRAFANA_USER="${GRAFANA_USER}"
GRAFANA_PASSWORD_B64="${GRAFANA_PASSWORD_B64}"

echo "==> Updating apt + installing Docker + Compose (if needed)"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker

case "\$REMOTE_DIR" in
  "~") REMOTE_DIR="\$HOME" ;;
  "~/"*) REMOTE_DIR="\$HOME/\${REMOTE_DIR#~/}" ;;
esac

GRAFANA_PASSWORD="\$(printf '%s' "\$GRAFANA_PASSWORD_B64" | base64 --decode)"

if ! docker compose version >/dev/null 2>&1; then
  echo "==> Installing Docker Compose"
  if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin
  elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose
  else
    echo "ERROR: no Compose package found (tried docker-compose-plugin, docker-compose-v2, docker-compose)." >&2
    exit 1
  fi
fi

if ! groups "\$USER" | grep -q "\\bdocker\\b"; then
  sudo usermod -aG docker "\$USER" || true
fi

echo "==> Creating monitoring directory"
sudo install -d -o "\$USER" -g "\$USER" -m 0755 "\$REMOTE_DIR"
sudo chown -R "\$USER:\$USER" "\$REMOTE_DIR"
cd "\$REMOTE_DIR"

echo "==> Writing prometheus.yml"
cat > prometheus.yml <<'YAML'
global:
  scrape_interval: 15s

scrape_configs:
  # Scrape jobs are managed by individual project deployment scripts
  # via their observability/grafana/import-dashboards.sh scripts
YAML

echo "==> Writing Grafana datasource provisioning"
mkdir -p grafana-provisioning/datasources
cat > grafana-provisioning/datasources/prometheus.yml <<'YAML'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
YAML

echo "==> Writing docker-compose.yml"
cat > docker-compose.yml <<YAML
version: "3.8"
services:
  prometheus:
    image: \${PROM_IMAGE}
    container_name: prometheus
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
      - "--web.enable-lifecycle"
    ports:
      - "\${PROM_HOST_PORT}:9090"
    restart: unless-stopped

  grafana:
    image: \${GRAFANA_IMAGE}
    container_name: grafana
    env_file:
      - ./grafana.env
    environment:
      # Correct external URL + sub-path (you already had these)
      - GF_SERVER_ROOT_URL=\${GRAFANA_ROOT_URL}
      - GF_SERVER_SERVE_FROM_SUB_PATH=true

      # IMPORTANT: stop Grafana thinking it's "localhost"
      - GF_SERVER_DOMAIN=\${GRAFANA_DOMAIN}

      # Helps avoid origin / host mismatches when behind reverse proxies
      - GF_SERVER_ENFORCE_DOMAIN=true

      # Recommended when serving over HTTPS at the edge (Cloudflare)
      - GF_SECURITY_COOKIE_SECURE=true
      - GF_SECURITY_COOKIE_SAMESITE=lax

      # Optional: if you use Grafana Live heavily behind proxies
      # - GF_LIVE_ALLOWED_ORIGINS=\${GRAFANA_ROOT_URL},https://\${GRAFANA_DOMAIN}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana-provisioning:/etc/grafana/provisioning:ro
    ports:
      - "\${GRAFANA_HOST_PORT}:3000"
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
YAML

echo "==> Writing grafana.env"
{
  printf 'GF_SECURITY_ADMIN_USER=%s\n' "\$GRAFANA_USER"
  printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "\$GRAFANA_PASSWORD"
} > grafana.env
chmod 600 grafana.env

echo "==> Starting services"
export PROM_IMAGE GRAFANA_IMAGE PROM_HOST_PORT GRAFANA_HOST_PORT GRAFANA_ROOT_URL GRAFANA_DOMAIN
if docker compose version >/dev/null 2>&1; then
  sudo docker compose up -d
elif command -v docker-compose >/dev/null 2>&1; then
  sudo docker-compose up -d
else
  echo "ERROR: Docker Compose is still unavailable after installation." >&2
  exit 1
fi

echo "==> Ensuring Grafana admin password matches configured secret"
grafana_password_set=0
for _attempt in \$(seq 1 30); do
  if sudo docker exec grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "\$GRAFANA_PASSWORD" >/dev/null 2>&1; then
    grafana_password_set=1
    break
  fi
  sleep 2
done

if [[ "\$grafana_password_set" != "1" ]]; then
  echo "ERROR: failed to set Grafana admin password after container startup" >&2
  exit 1
fi

echo
echo "==> Status"
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "==> Done."
echo "Prometheus: http://<YOUR_ORACLE_PUBLIC_IP>:\${PROM_HOST_PORT}"
echo "Grafana:    \${GRAFANA_ROOT_URL}  (login \${GRAFANA_USER}; password managed via ${GRAFANA_PASSWORD_SOURCE})"
EOF

echo
echo "==> Next:"
echo "1) In Oracle Cloud Security List / NSG, allow inbound TCP ${PROM_HOST_PORT} and ${GRAFANA_HOST_PORT} (or restrict to your IP)."
echo "2) Visit Grafana at ${GRAFANA_ROOT_URL} (Prometheus datasource is auto-provisioned)."
echo "3) Deploy your Node.js projects to automatically configure Prometheus scrape targets."
