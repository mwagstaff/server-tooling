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

PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:latest}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:latest}"

echo "==> Installing Prometheus + Grafana on: ${TARGET_HOST}"
echo "==> Remote dir: ${REMOTE_DIR}"
echo "==> Grafana port: ${GRAFANA_HOST_PORT} -> container 3000"
echo "==> Grafana root URL: ${GRAFANA_ROOT_URL}"
echo "==> Grafana domain: ${GRAFANA_DOMAIN}"
echo "==> Prometheus port: ${PROM_HOST_PORT} -> container 9090"
echo

ssh -o BatchMode=yes "${TARGET_HOST}" "bash -s" <<EOF
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR}"
GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT}"
PROM_HOST_PORT="${PROM_HOST_PORT}"
PROM_IMAGE="${PROM_IMAGE}"
GRAFANA_IMAGE="${GRAFANA_IMAGE}"
GRAFANA_ROOT_URL="${GRAFANA_ROOT_URL}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN}"

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
mkdir -p "\$REMOTE_DIR"
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

echo
echo "==> Status"
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "==> Done."
echo "Prometheus: http://<YOUR_ORACLE_PUBLIC_IP>:\${PROM_HOST_PORT}"
echo "Grafana:    \${GRAFANA_ROOT_URL}  (default login admin/admin)"
EOF

echo
echo "==> Next:"
echo "1) In Oracle Cloud Security List / NSG, allow inbound TCP ${PROM_HOST_PORT} and ${GRAFANA_HOST_PORT} (or restrict to your IP)."
echo "2) Visit Grafana at ${GRAFANA_ROOT_URL} (Prometheus datasource is auto-provisioned)."
echo "3) Deploy your Node.js projects to automatically configure Prometheus scrape targets."