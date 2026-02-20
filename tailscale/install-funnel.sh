#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-mikes-mac-mini}"
LABEL="com.mike.tailscale-funnel-apply"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES_DIR="${SCRIPT_DIR}/resources"

LOCAL_SCRIPT="${RES_DIR}/tailscale-funnel-apply.sh"
LOCAL_PLIST="${RES_DIR}/${LABEL}.plist"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

validate_routes() {
	log "Pre-deploy validation"

	if ! awk '
	$1 == "apply_route" {
		path = $2
		url = $3
		route_count++

		if (url !~ /^http:\/\/127\.0\.0\.1:[0-9]{1,5}(\/.*)?$/) {
			printf "Invalid route URL for %s: %s\n", path, url > "/dev/stderr"
			err = 1
			next
		}

		split(url, parts, ":")
		port_with_suffix = parts[3]
		split(port_with_suffix, port_parts, "/")
		port = port_parts[1] + 0

		if (port < 1 || port > 65535) {
			printf "Invalid port for %s: %s\n", path, port_parts[1] > "/dev/stderr"
			err = 1
			next
		}

		if (seen_port_to_path[port] != "") {
			printf "Duplicate port %d used by %s and %s\n", port, seen_port_to_path[port], path > "/dev/stderr"
			err = 1
			next
		}

		seen_port_to_path[port] = path
	}
	END {
		if (route_count == 0) {
			print "No apply_route entries found." > "/dev/stderr"
			err = 1
		}
		exit err
	}
	' "$LOCAL_SCRIPT"; then
		die "Pre-deploy validation failed. Fix route definitions in ${LOCAL_SCRIPT}."
	fi

	echo "Route validation passed."
}

[[ -f "$LOCAL_SCRIPT" ]] || die "Missing $LOCAL_SCRIPT"
[[ -f "$LOCAL_PLIST"  ]] || die "Missing $LOCAL_PLIST"

validate_routes

log "Installing LaunchAgent funnel config on ${HOST}"

TMP_SCRIPT="/tmp/tailscale-funnel-apply.sh.$$"
TMP_PLIST="/tmp/${LABEL}.plist.$$"

log "Uploading resources"
scp "${SSH_OPTS[@]}" "$LOCAL_SCRIPT" "${HOST}:${TMP_SCRIPT}"
scp "${SSH_OPTS[@]}" "$LOCAL_PLIST"  "${HOST}:${TMP_PLIST}"

log "Installing on remote host (macOS or Linux)"

# Pass temp paths and label as args so the heredoc can be quoted (no local expansion)
ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "${TMP_SCRIPT}" "${TMP_PLIST}" "${LABEL}" <<'EOF'
set -e

# positional args from local side
TMP_SCRIPT="${1}"
TMP_PLIST="${2}"
LABEL="${3}"

mkdir -p ~/bin

# install the script
install -m 0755 "${TMP_SCRIPT}" "${HOME}/bin/tailscale-funnel-apply.sh"
rm -f "${TMP_SCRIPT}"

OSNAME=$(uname -s || true)
if [[ "$OSNAME" == "Darwin" ]]; then
	mkdir -p ~/Library/LaunchAgents
	# replace hard-coded user path in the plist with the remote $HOME path
	sed "s|/Users/mwagstaff/bin/tailscale-funnel-apply.sh|${HOME}/bin/tailscale-funnel-apply.sh|" "${TMP_PLIST}" > "${HOME}/Library/LaunchAgents/${LABEL}.plist"
	rm -f "${TMP_PLIST}"

	launchctl unload "${HOME}/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null || true
	launchctl load "${HOME}/Library/LaunchAgents/${LABEL}.plist"
	echo "LaunchAgent installed."
else
	# Assume Linux (systemd). Install a user systemd unit if possible, otherwise try system unit with sudo.
	mkdir -p ~/.config/systemd/user
	UNIT_PATH="${HOME}/.config/systemd/user/${LABEL}.service"
	cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Tailscale Funnel Apply (user)
After=network.target

[Service]
Type=simple
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin
WorkingDirectory=${HOME}
ExecStart=${HOME}/bin/tailscale-funnel-apply.sh
Restart=on-failure
RestartSec=10
StandardOutput=append:/tmp/tailscale-funnel-apply.out.log
StandardError=append:/tmp/tailscale-funnel-apply.err.log

[Install]
WantedBy=default.target
UNIT

	rm -f "${TMP_PLIST}"

	# Try to enable via user systemd
	if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1; then
		systemctl --user enable --now "${LABEL}.service" || true
		echo "User systemd service installed."
	else
		# Fallback: try to install a system-wide unit using sudo
		if sudo -n true 2>/dev/null; then
			SVC_PATH="/etc/systemd/system/${LABEL}.service"
			sudo bash -c "cat > '${SVC_PATH}' <<SVC
		[Unit]
		Description=Tailscale Funnel Apply
		After=network.target

		[Service]
		Type=simple
		Environment=PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin
		WorkingDirectory=${HOME}
		ExecStart=${HOME}/bin/tailscale-funnel-apply.sh
		Restart=on-failure
		RestartSec=10
		User=${USER}
		StandardOutput=append:/tmp/tailscale-funnel-apply.out.log
		StandardError=append:/tmp/tailscale-funnel-apply.err.log

		[Install]
		WantedBy=multi-user.target
		SVC"
			sudo systemctl daemon-reload
			sudo systemctl enable --now "${LABEL}.service" || true
			echo "System systemd service installed (sudo)."
		else
			echo "Could not enable systemd service: no user/systemctl available and sudo not permitted." >&2
			echo "You can run '${HOME}/bin/tailscale-funnel-apply.sh' manually or enable systemd later."
		fi
	fi
fi
EOF

log "Verification"
ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "${LABEL}" <<'EOF'
set -e

LABEL="${1:-com.mike.tailscale-funnel-apply}"

resolve_tailscale_cli() {
	if command -v tailscale >/dev/null 2>&1; then
		command -v tailscale
		return 0
	fi

	for candidate in \
		/usr/local/bin/tailscale \
		/opt/homebrew/bin/tailscale \
		/usr/bin/tailscale \
		/snap/bin/tailscale \
		/Applications/Tailscale.app/Contents/MacOS/Tailscale \
		/Applications/Tailscale.app/Contents/MacOS/tailscale
	do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

OSNAME=$(uname -s || true)
if [[ "$OSNAME" == "Darwin" ]]; then
	launchctl list | grep tailscale-funnel || true
else
	# Check user service then system service
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user status "${LABEL}.service" >/dev/null 2>&1 || sudo systemctl status "${LABEL}.service" >/dev/null 2>&1 || true
	fi
fi
if TS_BIN="$(resolve_tailscale_cli)"; then
	"$TS_BIN" funnel status || true
else
	echo "tailscale CLI not found on remote host. Install Tailscale and ensure the CLI is available." >&2
fi
EOF

log "Done."
