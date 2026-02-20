#!/usr/bin/env zsh
set -euo pipefail

HOST="${1:-ocl}"

CADDY_LISTEN_IP="127.0.0.1"
CADDY_PORT="4080"

CADDYFILE="/etc/caddy/Caddyfile"
CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"

echo "==> Connecting to: ${HOST}"
echo "==> Will configure Caddy HTTP-only on: ${CADDY_LISTEN_IP}:${CADDY_PORT}"
echo

ssh "${HOST}" 'bash -s' <<'EOF'
set -euo pipefail

CADDY_LISTEN_IP="127.0.0.1"
CADDY_PORT="4080"
CADDYFILE="/etc/caddy/Caddyfile"
CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"

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

  # Normalize Grafana base path (Grafana expects a trailing slash)
  @grafana_base path /grafana
  redir @grafana_base /grafana/ 308

  # Grafana: keep /grafana prefix (Grafana is configured with root_url=https://api.skynolimit.dev/grafana)
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

echo "==> Updating cloudflared config (force http1 to origin + point to Caddy + correct Host header)..."
if [[ ! -f "${CLOUDFLARED_CONFIG}" ]]; then
  echo "ERROR: cloudflared config not found at ${CLOUDFLARED_CONFIG}"
  exit 1
fi

# Extract tunnel + credentials-file from existing config (so we don't hardcode UUID)
TUNNEL_NAME="$(sudo awk -F': *' '/^tunnel:/{print $2; exit}' "${CLOUDFLARED_CONFIG}")"
CREDS_FILE="$(sudo awk -F': *' '/^credentials-file:/{print $2; exit}' "${CLOUDFLARED_CONFIG}")"

if [[ -z "${TUNNEL_NAME}" || -z "${CREDS_FILE}" ]]; then
  echo "ERROR: could not parse tunnel/credentials-file from ${CLOUDFLARED_CONFIG}"
  echo "       tunnel='${TUNNEL_NAME}' creds='${CREDS_FILE}'"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
sudo cp -a "${CLOUDFLARED_CONFIG}" "${CLOUDFLARED_CONFIG}.bak.${TS}"

sudo tee "${CLOUDFLARED_CONFIG}" >/dev/null <<YAML
tunnel: ${TUNNEL_NAME}
credentials-file: ${CREDS_FILE}

ingress:
  - hostname: api.skynolimit.dev
    service: http://127.0.0.1:${CADDY_PORT}
    originRequest:
      http2Origin: false
      httpHostHeader: api.skynolimit.dev
  - service: http_status:404
YAML

# Guardrail: disableChunkedEncoding breaks our JSON bodies (0-byte responses)
if sudo grep -q "disableChunkedEncoding" "${CLOUDFLARED_CONFIG}"; then
  echo "ERROR: ${CLOUDFLARED_CONFIG} still contains disableChunkedEncoding; refusing to continue." >&2
  sudo sed -n '1,160p' "${CLOUDFLARED_CONFIG}" >&2
  exit 1
fi

echo "==> Restarting cloudflared..."
sudo systemctl restart cloudflared

echo "==> Final local sanity checks:"
echo "--> via Caddy:"
curl -i "http://${CADDY_LISTEN_IP}:${CADDY_PORT}/healthcheck" | head -n 20 || true

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
echo "==> Done. External tests:"
echo "    https://api.skynolimit.dev/healthcheck"
echo "    https://api.skynolimit.dev/grafana"
EOF

echo
echo "==> Finished remote setup on ${HOST}"