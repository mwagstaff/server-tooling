#!/usr/bin/env zsh
set -euo pipefail

HOST="${1:-ocl}"

CADDY_LISTEN_IP="127.0.0.1"
CADDY_PORT="4080"

CADDYFILE="/etc/caddy/Caddyfile"

echo "==> Connecting to: ${HOST}"
echo "==> Will configure Caddy HTTP-only on: ${CADDY_LISTEN_IP}:${CADDY_PORT}"
echo

ssh "${HOST}" 'bash -s' <<'EOF'
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

CADDY_LISTEN_IP="127.0.0.1"
CADDY_PORT="4080"
CADDYFILE="/etc/caddy/Caddyfile"
API_HOSTNAME="api.skynolimit.dev"
TOP_SCORES_HOSTNAME="top-scores.skynolimit.dev"
CLOUDFLARED_CONFIG_DIR="${HOME}/.cloudflared"
CLOUDFLARED_CONFIG="${CLOUDFLARED_CONFIG_DIR}/config.yml"
SYSTEM_CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
SYSTEM_CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"
SYSTEM_CLOUDFLARED_SERVICE="/etc/systemd/system/cloudflared.service"
TUNNEL_ID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

echo "==> Installing Caddy (if needed)..."
if ! command -v caddy >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y caddy
else
  echo "    Caddy already installed: $(caddy version || true)"
fi

echo "==> Writing Caddyfile (HTTP-only) to ${CADDYFILE}..."
sudo tee "${CADDYFILE}" >/dev/null <<CADDY
:${CADDY_PORT} {

  # Standalone Top Scores website on its own hostname.
  @top_scores_website host ${TOP_SCORES_HOSTNAME}
  handle @top_scores_website {
    reverse_proxy http://127.0.0.1:3020 {
      header_up Host {host}
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
      header_up X-Forwarded-Port 443
    }
  }

  # Normalize Grafana base path (Grafana expects a trailing slash)
  @grafana_base path /grafana
  redir @grafana_base /grafana/ 308

  # Grafana: keep /grafana prefix (Grafana is configured with root_url=https://${API_HOSTNAME}/grafana)
  # Important: tell Grafana the *external* scheme/host/prefix so it doesn't redirect-loop (/grafana/grafana/...)
  handle /grafana* {
    reverse_proxy http://127.0.0.1:3001 {
      header_up Host {host}
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
      header_up X-Forwarded-Port 443
      header_up X-Forwarded-Prefix /grafana
    }
  }

  # Healthcheck: /healthcheck -> / (matches old funnel mapping to :4000 root)
  @health path /healthcheck
  handle @health {
    rewrite * /
    reverse_proxy http://127.0.0.1:4000 {
      header_up Host 127.0.0.1
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
    }
  }

  # Other apps: strip prefix before proxying (matches old funnel mapping to root)
  handle_path /top-scores* {
    reverse_proxy http://127.0.0.1:3011 {
      header_up Host 127.0.0.1
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
    }
  }

  handle_path /train-track* {
    reverse_proxy http://127.0.0.1:3012 {
      header_up Host 127.0.0.1
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
    }
  }

  handle_path /bromley-bins* {
    reverse_proxy http://127.0.0.1:3013 {
      header_up Host 127.0.0.1
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
    }
  }

  handle_path /my-boris-bikes* {
    reverse_proxy http://127.0.0.1:3010 {
      header_up Host 127.0.0.1
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-Proto https
    }
  }

  handle {
    respond "not found" 404
  }
}
CADDY

echo "==> Enabling + restarting Caddy..."
sudo systemctl enable --now caddy
sudo systemctl restart caddy

echo "==> Local check: Caddy healthcheck should return JSON..."
curl -sS "http://${CADDY_LISTEN_IP}:${CADDY_PORT}/healthcheck" || true
echo

echo "==> Discovering Cloudflare tunnel..."
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ERROR: cloudflared is not installed or not on PATH." >&2
  exit 1
fi
CLOUDFLARED_BIN="$(command -v cloudflared)"

TUNNEL_LIST="$(cloudflared tunnel list)"
mapfile -t TUNNEL_IDS < <(printf '%s\n' "${TUNNEL_LIST}" | awk -v regex="${TUNNEL_ID_REGEX}" '$1 ~ regex { print $1 }')
mapfile -t TUNNEL_NAMES < <(printf '%s\n' "${TUNNEL_LIST}" | awk -v regex="${TUNNEL_ID_REGEX}" '$1 ~ regex { print $2 }')

if [[ ${#TUNNEL_IDS[@]} -ne 1 ]]; then
  echo "ERROR: expected exactly one Cloudflare tunnel, found ${#TUNNEL_IDS[@]}." >&2
  printf '%s\n' "${TUNNEL_LIST}" >&2
  exit 1
fi

TUNNEL_ID="${TUNNEL_IDS[0]}"
TUNNEL_NAME="${TUNNEL_NAMES[0]}"
CLOUDFLARED_CREDS_FILE="${CLOUDFLARED_CONFIG_DIR}/${TUNNEL_ID}.json"

if [[ ! -f "${CLOUDFLARED_CREDS_FILE}" ]]; then
  echo "==> Creating tunnel credentials at ${CLOUDFLARED_CREDS_FILE}..."
  mkdir -p "${CLOUDFLARED_CONFIG_DIR}"
  cloudflared tunnel token --cred-file "${CLOUDFLARED_CREDS_FILE}" "${TUNNEL_ID}" >/dev/null
fi

echo "    Using tunnel '${TUNNEL_NAME}' (${TUNNEL_ID})"

echo "==> Writing cloudflared config to ${CLOUDFLARED_CONFIG}..."
mkdir -p "${CLOUDFLARED_CONFIG_DIR}"
TS="$(date +%Y%m%d-%H%M%S)"
if [[ -f "${CLOUDFLARED_CONFIG}" ]]; then
  cp -a "${CLOUDFLARED_CONFIG}" "${CLOUDFLARED_CONFIG}.bak.${TS}"
fi

tee "${CLOUDFLARED_CONFIG}" >/dev/null <<YAML
tunnel: ${TUNNEL_ID}
credentials-file: ${CLOUDFLARED_CREDS_FILE}

ingress:
  - hostname: ${API_HOSTNAME}
    service: http://127.0.0.1:${CADDY_PORT}
    originRequest:
      http2Origin: false
      httpHostHeader: ${API_HOSTNAME}
  - hostname: ${TOP_SCORES_HOSTNAME}
    service: http://127.0.0.1:${CADDY_PORT}
    originRequest:
      http2Origin: false
      httpHostHeader: ${TOP_SCORES_HOSTNAME}
  - service: http_status:404
YAML

chmod 600 "${CLOUDFLARED_CONFIG}"

echo "==> Syncing cloudflared config for the system service..."
SYSTEM_CLOUDFLARED_CREDS_FILE="${SYSTEM_CLOUDFLARED_CONFIG_DIR}/${TUNNEL_ID}.json"
sudo install -d -m 0755 "${SYSTEM_CLOUDFLARED_CONFIG_DIR}"
if sudo test -f "${SYSTEM_CLOUDFLARED_CONFIG}"; then
  sudo cp -a "${SYSTEM_CLOUDFLARED_CONFIG}" "${SYSTEM_CLOUDFLARED_CONFIG}.bak.${TS}"
fi
if sudo test -f "${SYSTEM_CLOUDFLARED_CREDS_FILE}"; then
  sudo cp -a "${SYSTEM_CLOUDFLARED_CREDS_FILE}" "${SYSTEM_CLOUDFLARED_CREDS_FILE}.bak.${TS}"
fi
sudo install -m 0600 "${CLOUDFLARED_CREDS_FILE}" "${SYSTEM_CLOUDFLARED_CREDS_FILE}"
sudo tee "${SYSTEM_CLOUDFLARED_CONFIG}" >/dev/null <<YAML
tunnel: ${TUNNEL_ID}
credentials-file: ${SYSTEM_CLOUDFLARED_CREDS_FILE}

ingress:
  - hostname: ${API_HOSTNAME}
    service: http://127.0.0.1:${CADDY_PORT}
    originRequest:
      http2Origin: false
      httpHostHeader: ${API_HOSTNAME}
  - hostname: ${TOP_SCORES_HOSTNAME}
    service: http://127.0.0.1:${CADDY_PORT}
    originRequest:
      http2Origin: false
      httpHostHeader: ${TOP_SCORES_HOSTNAME}
  - service: http_status:404
YAML

# Guardrail: disableChunkedEncoding breaks our JSON bodies (0-byte responses)
if grep -q "disableChunkedEncoding" "${CLOUDFLARED_CONFIG}"; then
  echo "ERROR: ${CLOUDFLARED_CONFIG} still contains disableChunkedEncoding; refusing to continue." >&2
  sed -n '1,160p' "${CLOUDFLARED_CONFIG}" >&2
  exit 1
fi
if sudo grep -q "disableChunkedEncoding" "${SYSTEM_CLOUDFLARED_CONFIG}"; then
  echo "ERROR: ${SYSTEM_CLOUDFLARED_CONFIG} still contains disableChunkedEncoding; refusing to continue." >&2
  sudo sed -n '1,160p' "${SYSTEM_CLOUDFLARED_CONFIG}" >&2
  exit 1
fi

echo "==> Installing cloudflared systemd service..."
if sudo test -f "${SYSTEM_CLOUDFLARED_SERVICE}"; then
  sudo cp -a "${SYSTEM_CLOUDFLARED_SERVICE}" "${SYSTEM_CLOUDFLARED_SERVICE}.bak.${TS}"
fi
sudo tee "${SYSTEM_CLOUDFLARED_SERVICE}" >/dev/null <<UNIT
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} --no-autoupdate --config ${SYSTEM_CLOUDFLARED_CONFIG} tunnel run
Restart=always
RestartSec=5s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Enabling + restarting cloudflared..."
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo systemctl restart cloudflared
sudo systemctl --no-pager --full status cloudflared | sed -n '1,20p' || true

echo "==> Final local sanity checks:"
echo "--> via Caddy:"
curl -i "http://${CADDY_LISTEN_IP}:${CADDY_PORT}/healthcheck" | head -n 20 || true

echo
echo "--> via Caddy (Top Scores website hostname):"
curl -i -H "Host: ${TOP_SCORES_HOSTNAME}" "http://${CADDY_LISTEN_IP}:${CADDY_PORT}/" | head -n 20 || true

echo
echo "--> via Caddy (Grafana /grafana and /grafana/):"
# Show redirect for /grafana and confirm /grafana/ returns non-empty HTML
curl -i "http://${CADDY_LISTEN_IP}:${CADDY_PORT}/grafana" | head -n 20 || true
TMP_GRAFANA_HTML="$(mktemp)"
curl -sS -D - "http://${CADDY_LISTEN_IP}:${CADDY_PORT}/grafana/" -o "$TMP_GRAFANA_HTML" | head -n 20 || true
echo "Grafana HTML bytes (via Caddy): $(wc -c < "$TMP_GRAFANA_HTML" | tr -d ' ')"
rm -f "$TMP_GRAFANA_HTML"

echo
echo "--> direct service:"
curl -i "http://127.0.0.1:4000/" | head -n 20 || true

echo
echo "--> direct Top Scores website service:"
curl -i "http://127.0.0.1:3020/" | head -n 20 || true

echo
echo "==> Done. External tests:"
echo "    https://${API_HOSTNAME}/healthcheck"
echo "    https://${API_HOSTNAME}/grafana"
echo "    https://${TOP_SCORES_HOSTNAME}"
EOF

echo
echo "==> Finished remote setup on ${HOST}"
