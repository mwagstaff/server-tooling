#!/bin/bash
set -euo pipefail

readonly SERVICE_USER="mwagstaff"
readonly HELPER_SOURCE="${1:?helper source path is required}"
readonly HELPER_TARGET="/usr/local/sbin/train-track-boot-service-admin"
readonly SUDOERS_TARGET="/etc/sudoers.d/train-track-boot-service-admin"
readonly SUDOERS_TEMP="${SUDOERS_TARGET}.tmp.$$"

cleanup() {
  /bin/rm -f "$SUDOERS_TEMP"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || {
  echo "Error: installer must run as root." >&2
  exit 1
}
[[ -f "$HELPER_SOURCE" && ! -L "$HELPER_SOURCE" ]] || {
  echo "Error: helper source is missing or unsafe." >&2
  exit 1
}

/bin/bash -n "$HELPER_SOURCE"
/usr/bin/install -d -o root -g wheel -m 755 /usr/local/sbin
/usr/bin/install -d -o root -g wheel -m 755 /etc/sudoers.d
/usr/bin/install -o root -g wheel -m 755 "$HELPER_SOURCE" "$HELPER_TARGET"

cat > "$SUDOERS_TEMP" <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: $HELPER_TARGET
EOF
/usr/sbin/visudo -cf "$SUDOERS_TEMP" >/dev/null
/usr/bin/install -o root -g wheel -m 440 "$SUDOERS_TEMP" "$SUDOERS_TARGET"
/bin/rm -f "$HELPER_SOURCE"

"$HELPER_TARGET" check com.train-track-planner.api
"$HELPER_TARGET" check com.mike.tailscale-funnel-apply
echo "Installed restricted TrainTrack boot-service administrator."
