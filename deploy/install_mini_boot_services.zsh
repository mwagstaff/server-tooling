#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
HOST="${1:-mini}"
REMOTE_STAGE="/Users/mwagstaff/.local/share/server-tooling-bootstrap"
HELPER_NAME="train-track-boot-service-admin"
INSTALLER_NAME="install-train-track-boot-service-admin.sh"
FUNNEL_LABEL="com.mike.tailscale-funnel-apply"
FUNNEL_STAGE="/Users/mwagstaff/.local/share/server-tooling/.${FUNNEL_LABEL}.plist"

echo "==> Staging the restricted launchd helper on ${HOST}"
ssh "$HOST" "mkdir -p '$REMOTE_STAGE' /Users/mwagstaff/.local/share/server-tooling /Users/mwagstaff/bin /Users/mwagstaff/Library/Logs"
scp "$SCRIPT_DIR/macos/$HELPER_NAME" "$HOST:$REMOTE_STAGE/$HELPER_NAME"
scp "$SCRIPT_DIR/macos/$INSTALLER_NAME" "$HOST:$REMOTE_STAGE/$INSTALLER_NAME"

echo "==> One administrator confirmation is required on ${HOST}"
ssh -t "$HOST" "sudo /bin/bash '$REMOTE_STAGE/$INSTALLER_NAME' '$REMOTE_STAGE/$HELPER_NAME'"

echo "==> Installing the boot-scoped Tailscale Funnel job"
scp "$SCRIPT_DIR/tailscale-funnel-apply.sh" "$HOST:/Users/mwagstaff/bin/tailscale-funnel-apply.sh"
scp "$SCRIPT_DIR/../tailscale/resources/$FUNNEL_LABEL.plist" "$HOST:$FUNNEL_STAGE"
ssh "$HOST" "set -e; chmod 755 /Users/mwagstaff/bin/tailscale-funnel-apply.sh; chmod 600 '$FUNNEL_STAGE'; sudo -n /usr/local/sbin/$HELPER_NAME install '$FUNNEL_LABEL' '$FUNNEL_STAGE'; launchctl bootout gui/\$(id -u)/'$FUNNEL_LABEL' 2>/dev/null || true; launchctl bootout user/\$(id -u)/'$FUNNEL_LABEL' 2>/dev/null || true; rm -f \"\$HOME/Library/LaunchAgents/$FUNNEL_LABEL.plist\""

echo "==> Deploying the planner as a system LaunchDaemon"
"$SCRIPT_DIR/node_project.zsh" journey-planner "$HOST" --full --no-tail

echo "==> Verifying boot-scoped services"
ssh "$HOST" "launchctl print system/com.train-track-planner.api >/dev/null && launchctl print system/$FUNNEL_LABEL >/dev/null && curl -fsS --max-time 15 http://127.0.0.1:3014/healthcheck"
echo
echo "Migration complete."
