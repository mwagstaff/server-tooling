#!/usr/bin/env zsh
set -euo pipefail

# Install and configure node_exporter on a remote host
# Exposes system metrics on port 9100

TARGET_HOST="${1:-${TARGET_HOST:-ocl}}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.7.0}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"

echo "==> Installing node_exporter on: ${TARGET_HOST}"
echo "==> Version: ${NODE_EXPORTER_VERSION}"
echo "==> Port: ${NODE_EXPORTER_PORT}"
echo

ssh -o BatchMode=yes "${TARGET_HOST}" "bash -s" <<EOF
set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT}"

# Check if node_exporter is already running
if systemctl --user is-active node_exporter.service >/dev/null 2>&1; then
  echo "==> node_exporter is already running"
  systemctl --user status node_exporter.service --no-pager || true
  exit 0
fi

echo "==> Downloading node_exporter v\${NODE_EXPORTER_VERSION}"
cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v\${NODE_EXPORTER_VERSION}/node_exporter-\${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

echo "==> Extracting node_exporter"
tar xzf "node_exporter-\${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

echo "==> Installing to ~/bin"
mkdir -p "\$HOME/bin"
cp "node_exporter-\${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "\$HOME/bin/"
chmod +x "\$HOME/bin/node_exporter"

# Clean up
rm -rf "node_exporter-\${NODE_EXPORTER_VERSION}.linux-amd64"*

echo "==> Creating systemd user service"
mkdir -p "\$HOME/.config/systemd/user"

cat > "\$HOME/.config/systemd/user/node_exporter.service" <<'SERVICE'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=%h/bin/node_exporter --web.listen-address=:NODE_EXPORTER_PORT_PLACEHOLDER
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SERVICE

# Replace port placeholder
sed -i "s/NODE_EXPORTER_PORT_PLACEHOLDER/\${NODE_EXPORTER_PORT}/g" "\$HOME/.config/systemd/user/node_exporter.service"

echo "==> Enabling and starting node_exporter service"
systemctl --user daemon-reload
systemctl --user enable node_exporter.service
systemctl --user start node_exporter.service

echo "==> Service status"
systemctl --user status node_exporter.service --no-pager || true

echo
echo "==> node_exporter is now running on port \${NODE_EXPORTER_PORT}"
echo "==> Test with: curl http://localhost:\${NODE_EXPORTER_PORT}/metrics"
EOF

echo
echo "✅ node_exporter installation complete"
echo
echo "Next steps:"
echo "1. Configure Prometheus to scrape node_exporter at ${TARGET_HOST}:${NODE_EXPORTER_PORT}"
echo "2. Add firewall rule if needed to allow Prometheus container to access port ${NODE_EXPORTER_PORT}"
