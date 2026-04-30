#!/usr/bin/env zsh
set -euo pipefail

TARGET_HOST="${1:-${TARGET_HOST:-sky}}"
LOCAL_CERTS_DIR="${LOCAL_CERTS_DIR:-/Users/mwagstaff/Library/Mobile Documents/com~apple~CloudDocs/dev/certs}"
REMOTE_CERTS_DIR="${REMOTE_CERTS_DIR:-~/.certs}"

if [[ ! -d "$LOCAL_CERTS_DIR" ]]; then
  echo "Error: local certs directory not found: $LOCAL_CERTS_DIR" >&2
  exit 1
fi

echo "==> Deploying certs to: ${TARGET_HOST}"
echo "==> Local certs dir: ${LOCAL_CERTS_DIR}"
echo "==> Remote certs dir: ${REMOTE_CERTS_DIR}"

echo "==> Ensuring remote certs directory exists with secure permissions..."
ssh "$TARGET_HOST" "
  set -euo pipefail
  REMOTE_CERTS_DIR=\$(eval echo \"$REMOTE_CERTS_DIR\")
  install -d -m 700 \"\$REMOTE_CERTS_DIR\"
  chmod 700 \"\$REMOTE_CERTS_DIR\"
"

echo "==> Syncing certs..."
rsync -az --delete \
  --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= \
  "$LOCAL_CERTS_DIR/" \
  "${TARGET_HOST}:${REMOTE_CERTS_DIR}/"

echo "==> Re-securing remote certs directory..."
ssh "$TARGET_HOST" "
  set -euo pipefail
  REMOTE_CERTS_DIR=\$(eval echo \"$REMOTE_CERTS_DIR\")
  chmod 700 \"\$REMOTE_CERTS_DIR\"
  find \"\$REMOTE_CERTS_DIR\" -type d -exec chmod 700 {} +
  find \"\$REMOTE_CERTS_DIR\" -type f -exec chmod 600 {} +
"

echo
echo "==> Done."
echo "Remote certs are available at ${TARGET_HOST}:${REMOTE_CERTS_DIR}"
