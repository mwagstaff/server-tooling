#!/usr/bin/env zsh
set -euo pipefail

# Patch and harden an Ubuntu host over SSH.
#
# Defaults are tuned for the Hetzner host alias "sky".
#
# Usage:
#   ./patching/patch_sky_host.zsh [HOST_ALIAS] [OPTIONS]
#
# Examples:
#   ./patching/patch_sky_host.zsh
#   ./patching/patch_sky_host.zsh sky --dry-run
#   ./patching/patch_sky_host.zsh sky --npm-project-roots '$HOME/dev' --compose-dirs '$HOME/monitoring'
#
# Options:
#   --dry-run                 Show planned remote changes only
#   --email EMAIL             Email for logwatch/debsecan output
#   --reboot-time HH:MM       Automatic reboot time for unattended-upgrades
#   --full-upgrade-time TIME  Weekly systemd OnCalendar time, e.g. Sun 04:00
#   --npm-project-roots DIRS  Comma-separated remote roots scanned for package.json, default ~/dev
#   --npm-project-dirs DIRS   Alias for --npm-project-roots
#   --compose-dirs DIRS       Comma-separated remote dirs where docker compose pull/up runs, default ~/monitoring
#   --allow-ports PORTS       Comma-separated UFW TCP ports to allow, default 80,443
#   --skip-stack-updates      Skip npm/docker/cloudflared/tailscale update attempts
#   --skip-livepatch          Skip canonical-livepatch snap install
#   --skip-ssh-hardening      Do not enforce SSH hardening drop-in
#   --skip-ufw                Do not install/configure/enable UFW
#   -h, --help                Show help

TARGET_HOST="${TARGET_HOST:-sky}"
DRY_RUN=0
EMAIL="${PATCH_ALERT_EMAIL:-mike.wagstaff@gmail.com}"
REBOOT_TIME="${PATCH_REBOOT_TIME:-03:30}"
FULL_UPGRADE_TIME="${PATCH_FULL_UPGRADE_TIME:-Sun 04:00}"
# monitoring/install-monitoring.zsh writes the Prometheus/Grafana compose stack to REMOTE_DIR,
# whose default is $HOME/monitoring on the remote host.
NPM_PROJECT_ROOTS="${PATCH_NPM_PROJECT_ROOTS:-${PATCH_NPM_PROJECT_DIRS:-~/dev}}"
COMPOSE_DIRS="${PATCH_COMPOSE_DIRS:-~/monitoring}"
ALLOW_PORTS="${PATCH_ALLOW_PORTS:-80,443}"
SKIP_STACK_UPDATES=0
SKIP_LIVEPATCH=0
SKIP_SSH_HARDENING=0
SKIP_UFW=0

usage() {
  cat <<'EOF'
Patch and harden an Ubuntu host over SSH.

Defaults are tuned for the Hetzner host alias "sky".

Usage:
  ./patching/patch_sky_host.zsh [HOST_ALIAS] [OPTIONS]

Examples:
  ./patching/patch_sky_host.zsh
  ./patching/patch_sky_host.zsh sky --dry-run
  ./patching/patch_sky_host.zsh sky --npm-project-roots '$HOME/dev' --compose-dirs '$HOME/monitoring'

Options:
  --dry-run                 Show planned remote changes only
  --email EMAIL             Email for logwatch/debsecan output
  --reboot-time HH:MM       Automatic reboot time for unattended-upgrades
  --full-upgrade-time TIME  Weekly systemd OnCalendar time, e.g. Sun 04:00
  --npm-project-roots DIRS  Comma-separated remote roots scanned for package.json, default ~/dev
  --npm-project-dirs DIRS   Alias for --npm-project-roots
  --compose-dirs DIRS       Comma-separated remote dirs where docker compose pull/up runs, default ~/monitoring
  --allow-ports PORTS       Comma-separated UFW TCP ports to allow, default 80,443
  --skip-stack-updates      Skip npm/docker/cloudflared/tailscale update attempts
  --skip-livepatch          Skip canonical-livepatch snap install
  --skip-ssh-hardening      Do not enforce SSH hardening drop-in
  --skip-ufw                Do not install/configure/enable UFW
  -h, --help                Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --email)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --email" >&2
        exit 1
      fi
      EMAIL="$2"
      shift 2
      ;;
    --reboot-time)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --reboot-time" >&2
        exit 1
      fi
      REBOOT_TIME="$2"
      shift 2
      ;;
    --full-upgrade-time)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --full-upgrade-time" >&2
        exit 1
      fi
      FULL_UPGRADE_TIME="$2"
      shift 2
      ;;
    --npm-project-roots|--npm-project-dirs)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      NPM_PROJECT_ROOTS="$2"
      shift 2
      ;;
    --compose-dirs)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --compose-dirs" >&2
        exit 1
      fi
      COMPOSE_DIRS="$2"
      shift 2
      ;;
    --allow-ports)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --allow-ports" >&2
        exit 1
      fi
      ALLOW_PORTS="$2"
      shift 2
      ;;
    --skip-stack-updates)
      SKIP_STACK_UPDATES=1
      shift
      ;;
    --skip-livepatch)
      SKIP_LIVEPATCH=1
      shift
      ;;
    --skip-ssh-hardening)
      SKIP_SSH_HARDENING=1
      shift
      ;;
    --skip-ufw)
      SKIP_UFW=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      TARGET_HOST="$1"
      shift
      ;;
  esac
done

if [[ ! "${REBOOT_TIME}" =~ '^[0-2][0-9]:[0-5][0-9]$' ]]; then
  echo "--reboot-time must be HH:MM" >&2
  exit 1
fi

shell_quote() {
  printf "%q" "$1"
}

echo "==> Patching and hardening host: ${TARGET_HOST}"
echo "==> dry_run=${DRY_RUN} email=${EMAIL} reboot_time=${REBOOT_TIME} full_upgrade_time=${FULL_UPGRADE_TIME}"
echo "==> npm_project_roots=${NPM_PROJECT_ROOTS:-none} compose_dirs=${COMPOSE_DIRS:-none} allow_ports=${ALLOW_PORTS}"
echo "==> skip_stack_updates=${SKIP_STACK_UPDATES} skip_livepatch=${SKIP_LIVEPATCH} skip_ssh_hardening=${SKIP_SSH_HARDENING} skip_ufw=${SKIP_UFW}"
echo

ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET_HOST}" \
  "DRY_RUN=$(shell_quote "${DRY_RUN}") ALERT_EMAIL=$(shell_quote "${EMAIL}") REBOOT_TIME=$(shell_quote "${REBOOT_TIME}") FULL_UPGRADE_TIME=$(shell_quote "${FULL_UPGRADE_TIME}") NPM_PROJECT_ROOTS=$(shell_quote "${NPM_PROJECT_ROOTS}") COMPOSE_DIRS=$(shell_quote "${COMPOSE_DIRS}") ALLOW_PORTS=$(shell_quote "${ALLOW_PORTS}") SKIP_STACK_UPDATES=$(shell_quote "${SKIP_STACK_UPDATES}") SKIP_LIVEPATCH=$(shell_quote "${SKIP_LIVEPATCH}") SKIP_SSH_HARDENING=$(shell_quote "${SKIP_SSH_HARDENING}") SKIP_UFW=$(shell_quote "${SKIP_UFW}") bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

print_section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

SUDO=()
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO=(sudo -n)
  else
    SUDO=(sudo)
  fi
fi

run_priv() {
  "${SUDO[@]}" "$@"
}

run_cmd() {
  if [ "${DRY_RUN}" = "1" ]; then
    echo "[dry-run] $*"
  else
    run_priv "$@"
  fi
}

run_in_dir() {
  local dir="$1"
  shift
  if [ "${DRY_RUN}" = "1" ]; then
    echo "[dry-run] (cd ${dir} && $*)"
  else
    (
      cd "${dir}"
      run_priv "$@"
    )
  fi
}

expand_remote_path() {
  local path="$1"
  case "${path}" in
    "~") printf '%s\n' "${HOME}" ;;
    "~/"*) printf '%s/%s\n' "${HOME}" "${path#~/}" ;;
    '$HOME') printf '%s\n' "${HOME}" ;;
    '$HOME/'*) printf '%s/%s\n' "${HOME}" "${path#\$HOME/}" ;;
    '${HOME}') printf '%s\n' "${HOME}" ;;
    '${HOME}/'*) printf '%s/%s\n' "${HOME}" "${path#\$\{HOME\}/}" ;;
    *) printf '%s\n' "${path}" ;;
  esac
}

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value}"
}

discover_npm_project_dirs() {
  local roots_csv="$1"
  local root
  IFS=',' read -r -a roots <<<"${roots_csv}"
  for root in "${roots[@]}"; do
    root="$(trim_space "${root}")"
    [ -n "${root}" ] || continue
    root="$(expand_remote_path "${root}")"
    if [ ! -d "${root}" ]; then
      echo "Skipping npm root; directory not found: ${root}" >&2
      continue
    fi
    find "${root}" \
      -path '*/node_modules' -prune -o \
      -path '*/.git' -prune -o \
      -path '*/dist' -prune -o \
      -path '*/build' -prune -o \
      -name package.json -type f -print \
      | while IFS= read -r package_json; do
          dirname "${package_json}"
        done
  done | sort -u
}

write_root_file() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}"

  if [ -f "${path}" ] && cmp -s "${tmp}" "${path}"; then
    echo "Unchanged: ${path}"
    rm -f "${tmp}"
    return
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    echo "[dry-run] update ${path}"
    if [ -f "${path}" ]; then
      diff -u "${path}" "${tmp}" || true
    else
      sed 's/^/+/' "${tmp}"
    fi
    rm -f "${tmp}"
    return
  fi

  run_priv install -o "${owner}" -g "${group}" -m "${mode}" "${tmp}" "${path}"
  rm -f "${tmp}"
  echo "Updated: ${path}"
}

systemctl_reload_enable_now() {
  local unit="$1"
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable --now "${unit}"
}

ensure_min_swap() {
  local min_bytes=$((2 * 1024 * 1024 * 1024))
  local swapfile="/swapfile"
  local active_swap_bytes file_size

  active_swap_bytes="$(awk 'NR>1 {total += $3 * 1024} END {printf "%.0f", total + 0}' /proc/swaps)"
  if [ "${active_swap_bytes}" -ge "${min_bytes}" ]; then
    health_ok "Swap enabled: $((active_swap_bytes / 1024 / 1024)) MB"
    return
  fi

  print_section "Swap"
  echo "Active swap is below 2 GB; ensuring ${swapfile} exists and is enabled."

  if [ -e "${swapfile}" ]; then
    file_size="$(stat -c '%s' "${swapfile}" 2>/dev/null || echo 0)"
    if [ "${file_size}" -lt "${min_bytes}" ]; then
      if [ "${DRY_RUN}" = "1" ]; then
        echo "[dry-run] swapoff ${swapfile} if active; resize ${swapfile} to 2G"
      else
        run_priv swapoff "${swapfile}" 2>/dev/null || true
        run_priv fallocate -l 2G "${swapfile}"
      fi
    fi
  else
    run_cmd fallocate -l 2G "${swapfile}"
  fi

  run_cmd chmod 600 "${swapfile}"

  if [ "${DRY_RUN}" = "1" ]; then
    echo "[dry-run] mkswap ${swapfile} if it is not an initialized swap area"
  elif ! run_priv file "${swapfile}" | grep -q 'swap file'; then
    run_priv mkswap "${swapfile}"
  fi

  if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+' /etc/fstab; then
    if [ "${DRY_RUN}" = "1" ]; then
      echo "[dry-run] append '/swapfile none swap sw 0 0' to /etc/fstab"
    else
      printf '%s\n' '/swapfile none swap sw 0 0' | run_priv tee -a /etc/fstab >/dev/null
    fi
  else
    echo "Unchanged: /etc/fstab already contains ${swapfile}"
  fi

  if ! awk 'NR>1 && $1 == "/swapfile" {found=1} END {exit found ? 0 : 1}' /proc/swaps; then
    run_cmd swapon "${swapfile}"
  else
    echo "Swap already active: ${swapfile}"
  fi
}

health_ok() {
  printf 'OK    %s\n' "$1"
}

health_warn() {
  printf 'WARN  %s\n' "$1"
}

health_info() {
  printf 'INFO  %s\n' "$1"
}

health_service() {
  local unit="$1"
  local label="$2"
  local active enabled
  active="$(run_priv systemctl is-active "${unit}" 2>/dev/null || true)"
  enabled="$(run_priv systemctl is-enabled "${unit}" 2>/dev/null || true)"
  if [ "${active}" = "active" ] && { [ "${enabled}" = "enabled" ] || [ "${enabled}" = "static" ]; }; then
    health_ok "${label}: active (${unit}, enabled=${enabled})"
  else
    health_warn "${label}: active=${active:-unknown}, enabled=${enabled:-unknown} (${unit})"
  fi
}

health_timer() {
  local unit="$1"
  local label="$2"
  local active enabled next
  active="$(run_priv systemctl is-active "${unit}" 2>/dev/null || true)"
  enabled="$(run_priv systemctl is-enabled "${unit}" 2>/dev/null || true)"
  next="$(run_priv systemctl list-timers "${unit}" --no-legend --no-pager 2>/dev/null | awk '{print $1" "$2" "$3" "$4}' || true)"
  if [ "${active}" = "active" ] && [ "${enabled}" = "enabled" ]; then
    health_ok "${label}: active, next=${next:-unknown}"
  else
    health_warn "${label}: active=${active:-unknown}, enabled=${enabled:-unknown}, next=${next:-unknown}"
  fi
}

print_health_summary() {
  print_section "Health Summary"

  if [ "${DRY_RUN}" = "1" ]; then
    health_info "Dry run only; health checks reflect the current host state before changes."
  fi

  local active_swap_bytes
  active_swap_bytes="$(awk 'NR>1 {total += $3 * 1024} END {printf "%.0f", total + 0}' /proc/swaps)"
  if [ "${active_swap_bytes}" -ge "$((2 * 1024 * 1024 * 1024))" ]; then
    health_ok "Swap enabled: $((active_swap_bytes / 1024 / 1024)) MB"
  else
    health_warn "Swap below 2 GB: $((active_swap_bytes / 1024 / 1024)) MB"
  fi

  health_service unattended-upgrades "Automatic security updates"
  health_timer apt-daily-upgrade.timer "APT unattended upgrade timer"
  health_timer server-tooling-full-upgrade.timer "Weekly full-upgrade timer"
  health_service fail2ban "Fail2ban"
  health_service auditd "auditd"

  if run_priv systemctl list-unit-files ufw.service >/dev/null 2>&1; then
    health_service ufw "UFW service"
  fi

  for unit in \
    server-tooling-debsecan-report.timer \
    server-tooling-logwatch-report.timer \
    server-tooling-rkhunter-check.timer; do
    health_timer "${unit}" "${unit%.timer}"
  done

  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status="$(run_priv ufw status 2>/dev/null || true)"
    if printf '%s\n' "${ufw_status}" | grep -qi '^Status: active'; then
      health_ok "UFW firewall is active"
      printf '%s\n' "${ufw_status}" | sed 's/^/      /'
    else
      health_warn "UFW firewall is not active"
      printf '%s\n' "${ufw_status}" | sed 's/^/      /'
    fi
  fi

  if command -v fail2ban-client >/dev/null 2>&1; then
    local f2b_status
    f2b_status="$(run_priv fail2ban-client status sshd 2>/dev/null || true)"
    if printf '%s\n' "${f2b_status}" | grep -q 'Jail list\|Currently banned\|Total banned'; then
      health_ok "Fail2ban sshd jail is queryable"
      printf '%s\n' "${f2b_status}" | sed 's/^/      /'
    else
      health_warn "Fail2ban sshd jail did not return status"
      printf '%s\n' "${f2b_status}" | sed 's/^/      /'
    fi
  fi

  if command -v sshd >/dev/null 2>&1; then
    local ssh_effective
    ssh_effective="$(run_priv sshd -T 2>/dev/null | awk '$1=="permitrootlogin" || $1=="passwordauthentication" || $1=="kbdinteractiveauthentication" || $1=="pubkeyauthentication" {print $1" "$2}' || true)"
    if printf '%s\n' "${ssh_effective}" | grep -qx 'permitrootlogin no' \
      && printf '%s\n' "${ssh_effective}" | grep -qx 'passwordauthentication no' \
      && printf '%s\n' "${ssh_effective}" | grep -qx 'pubkeyauthentication yes'; then
      health_ok "SSH hardening effective"
    else
      health_warn "SSH hardening needs review"
    fi
    printf '%s\n' "${ssh_effective}" | sed 's/^/      /'
  fi

  if [ -f /var/run/reboot-required ]; then
    health_warn "Reboot required"
    if [ -f /var/run/reboot-required.pkgs ]; then
      sed 's/^/      /' /var/run/reboot-required.pkgs || true
    fi
  else
    health_ok "No reboot currently required"
  fi

  if command -v apt >/dev/null 2>&1; then
    local pending_updates security_updates
    pending_updates="$(apt list --upgradable 2>/dev/null | sed '1d' | wc -l | tr -d ' ')"
    security_updates="$(apt list --upgradable 2>/dev/null | sed '1d' | grep -c -- '-security' || true)"
    if [ "${pending_updates:-0}" = "0" ]; then
      health_ok "No pending apt package updates"
    else
      health_warn "Pending apt updates: ${pending_updates} total, ${security_updates} likely security"
    fi
  fi

  if command -v debsecan >/dev/null 2>&1; then
    local suite debsecan_count
    suite="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    if [ -n "${suite}" ]; then
      debsecan_count="$(debsecan --suite "${suite}" --format packages 2>/dev/null | wc -l | tr -d ' ' || true)"
    else
      debsecan_count="$(debsecan --format packages 2>/dev/null | wc -l | tr -d ' ' || true)"
    fi
    if [ "${debsecan_count:-0}" = "0" ]; then
      health_ok "debsecan reports no vulnerable packages"
    else
      health_warn "debsecan reports ${debsecan_count} vulnerable package entries"
      health_info "Run: sudo debsecan --suite ${suite:-<codename>} --format detail"
    fi
  fi

  if command -v rkhunter >/dev/null 2>&1; then
    local rkhunter_log rkhunter_warnings
    rkhunter_log="/var/log/rkhunter.log"
    if [ -r "${rkhunter_log}" ]; then
      rkhunter_warnings="$(grep -ci 'warning' "${rkhunter_log}" || true)"
      if [ "${rkhunter_warnings:-0}" = "0" ]; then
        health_ok "rkhunter log has no warnings"
      else
        health_warn "rkhunter log contains ${rkhunter_warnings} warning lines"
        health_info "Run: sudo rkhunter --check --sk --rwo"
      fi
    else
      health_info "rkhunter log not present yet; first scheduled scan will create it"
    fi
  fi

  if command -v mailq >/dev/null 2>&1; then
    local mailq_output mailq_count
    mailq_output="$(mailq 2>/dev/null || true)"
    if printf '%s\n' "${mailq_output}" | grep -q 'Mail queue is empty'; then
      health_ok "Local mail queue is empty"
    else
      mailq_count="$(printf '%s\n' "${mailq_output}" | grep -c '^[A-F0-9]' || true)"
      health_warn "Local mail queue has ${mailq_count:-unknown} queued item(s); outbound SMTP may be blocked"
      health_info "Reports are still available locally via journalctl and the commands shown above."
    fi
  else
    health_info "mailq is unavailable; SMTP delivery state was not checked"
  fi

  local failed_units
  failed_units="$(run_priv systemctl --failed --no-legend --no-pager 2>/dev/null || true)"
  if [ -z "${failed_units}" ]; then
    health_ok "No failed systemd units"
  else
    health_warn "Failed systemd units detected"
    printf '%s\n' "${failed_units}" | sed 's/^/      /'
  fi
}

DRY_RUN="${DRY_RUN:-0}"
ALERT_EMAIL="${ALERT_EMAIL:-mike.wagstaff@gmail.com}"
REBOOT_TIME="${REBOOT_TIME:-03:30}"
FULL_UPGRADE_TIME="${FULL_UPGRADE_TIME:-Sun 04:00}"
NPM_PROJECT_ROOTS="${NPM_PROJECT_ROOTS:-~/dev}"
COMPOSE_DIRS="${COMPOSE_DIRS:-~/monitoring}"
ALLOW_PORTS="${ALLOW_PORTS:-80,443}"
SKIP_STACK_UPDATES="${SKIP_STACK_UPDATES:-0}"
SKIP_LIVEPATCH="${SKIP_LIVEPATCH:-0}"
SKIP_SSH_HARDENING="${SKIP_SSH_HARDENING:-0}"
SKIP_UFW="${SKIP_UFW:-0}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script supports Ubuntu/Debian apt hosts only." >&2
  exit 1
fi

print_section "Host Information"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "OS: ${PRETTY_NAME:-unknown}"
echo "Kernel: $(uname -r)"
echo "Time UTC: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

ensure_min_swap

print_section "APT Packages"
run_cmd apt-get update
run_cmd apt-get install -y \
  unattended-upgrades \
  apt-listchanges \
  needrestart \
  ufw \
  fail2ban \
  debsecan \
  logwatch \
  rkhunter \
  auditd \
  apt-transport-https \
  ca-certificates

print_section "Unattended Security Updates"
write_root_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root root <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

write_root_file /etc/apt/apt.conf.d/52server-tooling-unattended-upgrades 0644 root root <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=Ubuntu,codename=\${distro_codename}-security,label=Ubuntu";
        "origin=UbuntuESMApps,codename=\${distro_codename}-apps-security,label=UbuntuESMApps";
        "origin=UbuntuESM,codename=\${distro_codename}-infra-security,label=UbuntuESM";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::Mail "${ALERT_EMAIL}";
Unattended-Upgrade::MailReport "on-change";
EOF

run_cmd systemctl enable --now unattended-upgrades
run_cmd systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

print_section "Weekly Full Upgrade Timer"
write_root_file /usr/local/sbin/server-tooling-full-upgrade 0755 root root <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update
apt-get full-upgrade -y
apt-get autoremove --purge -y
apt-get autoclean -y
EOF

write_root_file /etc/systemd/system/server-tooling-full-upgrade.service 0644 root root <<'EOF'
[Unit]
Description=Server Tooling weekly apt full-upgrade
Documentation=man:apt-get(8)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/server-tooling-full-upgrade
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

write_root_file /etc/systemd/system/server-tooling-full-upgrade.timer 0644 root root <<EOF
[Unit]
Description=Run Server Tooling weekly apt full-upgrade

[Timer]
OnCalendar=${FULL_UPGRADE_TIME}
Persistent=true
RandomizedDelaySec=20m
Unit=server-tooling-full-upgrade.service

[Install]
WantedBy=timers.target
EOF

systemctl_reload_enable_now server-tooling-full-upgrade.timer

print_section "needrestart"
write_root_file /etc/needrestart/conf.d/99-server-tooling.conf 0644 root root <<'EOF'
$nrconf{restart} = 'l';
$nrconf{kernelhints} = 1;
EOF
if [ "${DRY_RUN}" = "1" ]; then
  echo "[dry-run] needrestart -r l"
else
  run_priv needrestart -r l || true
fi

print_section "SSH Hardening"
if [ "${SKIP_SSH_HARDENING}" = "1" ]; then
  echo "Skipping SSH hardening."
else
  run_cmd install -d -m 0755 /etc/ssh/sshd_config.d
  write_root_file /etc/ssh/sshd_config.d/99-server-tooling-hardening.conf 0644 root root <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
EOF
  run_cmd sshd -t
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run_cmd systemctl reload ssh
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    run_cmd systemctl reload sshd
  else
    echo "SSH unit not found; config validated but service was not reloaded."
  fi
fi

print_section "UFW Firewall"
if [ "${SKIP_UFW}" = "1" ]; then
  echo "Skipping UFW."
else
  run_cmd ufw --force default deny incoming
  run_cmd ufw --force default allow outgoing
  if ufw app info OpenSSH >/dev/null 2>&1; then
    run_cmd ufw allow OpenSSH
  fi
  mapfile -t SSH_PORTS < <(run_priv sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -u)
  if [ "${#SSH_PORTS[@]}" -eq 0 ]; then
    SSH_PORTS=(22)
  fi
  for port in "${SSH_PORTS[@]}"; do
    run_cmd ufw allow "${port}/tcp"
  done
  IFS=',' read -r -a EXTRA_PORTS <<<"${ALLOW_PORTS}"
  for port in "${EXTRA_PORTS[@]}"; do
    port="${port//[[:space:]]/}"
    if [[ -n "${port}" ]]; then
      run_cmd ufw allow "${port}/tcp"
    fi
  done
  run_cmd ufw logging on
  run_cmd ufw --force enable
  run_cmd systemctl enable --now ufw
fi

print_section "fail2ban"
write_root_file /etc/fail2ban/jail.d/99-server-tooling.local 0644 root root <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
mode = aggressive
EOF
run_cmd systemctl enable --now fail2ban
run_cmd systemctl restart fail2ban

print_section "Security Scan Timers"
write_root_file /etc/default/debsecan 0644 root root <<EOF
REPORT=true
MAILTO=${ALERT_EMAIL}
SOURCE=
SUITE=
SUBJECT='debsecan security report for $(hostname -f 2>/dev/null || hostname)'
EOF

write_root_file /usr/local/sbin/server-tooling-debsecan-report 0755 root root <<EOF
#!/usr/bin/env bash
set -euo pipefail
tmp="\$(mktemp)"
trap 'rm -f "\${tmp}"' EXIT
suite="\$(. /etc/os-release && echo "\${VERSION_CODENAME:-}")"
if [ -n "\${suite}" ]; then
  debsecan --suite "\${suite}" --format detail >"\${tmp}" 2>&1 || true
else
  debsecan --format detail >"\${tmp}" 2>&1 || true
fi
if command -v mail >/dev/null 2>&1; then
  mail -s "debsecan security report for \$(hostname -f 2>/dev/null || hostname)" "${ALERT_EMAIL}" <"\${tmp}" || true
else
  cat "\${tmp}"
fi
EOF

write_root_file /usr/local/sbin/server-tooling-logwatch-report 0755 root root <<EOF
#!/usr/bin/env bash
set -euo pipefail
logwatch --detail high --mailto "${ALERT_EMAIL}" --range yesterday || true
EOF

write_root_file /usr/local/sbin/server-tooling-rkhunter-check 0755 root root <<EOF
#!/usr/bin/env bash
set -euo pipefail
tmp="\$(mktemp)"
trap 'rm -f "\${tmp}"' EXIT
rkhunter --update || true
if [ ! -s /var/lib/rkhunter/db/rkhunter.dat ]; then
  rkhunter --propupd || true
fi
rkhunter --check --sk --rwo >"\${tmp}" 2>&1 || true
if command -v mail >/dev/null 2>&1; then
  mail -s "rkhunter report for \$(hostname -f 2>/dev/null || hostname)" "${ALERT_EMAIL}" <"\${tmp}" || true
else
  cat "\${tmp}"
fi
EOF

for unit in debsecan-report logwatch-report rkhunter-check; do
  case "${unit}" in
    debsecan-report)
      desc="Run debsecan security report"
      calendar="daily"
      exec_path="/usr/local/sbin/server-tooling-debsecan-report"
      ;;
    logwatch-report)
      desc="Run logwatch report"
      calendar="daily"
      exec_path="/usr/local/sbin/server-tooling-logwatch-report"
      ;;
    rkhunter-check)
      desc="Run rkhunter check"
      calendar="weekly"
      exec_path="/usr/local/sbin/server-tooling-rkhunter-check"
      ;;
  esac
  write_root_file "/etc/systemd/system/server-tooling-${unit}.service" 0644 root root <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${exec_path}
EOF
  write_root_file "/etc/systemd/system/server-tooling-${unit}.timer" 0644 root root <<EOF
[Unit]
Description=${desc}

[Timer]
OnCalendar=${calendar}
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
  systemctl_reload_enable_now "server-tooling-${unit}.timer"
done

if [ "${DRY_RUN}" = "1" ]; then
  echo "[dry-run] logwatch --detail high --mailto ${ALERT_EMAIL} --range today"
else
  run_priv logwatch --detail high --mailto "${ALERT_EMAIL}" --range today || true
fi

print_section "auditd"
run_cmd systemctl enable --now auditd

print_section "Kernel Livepatch"
if [ "${SKIP_LIVEPATCH}" = "1" ]; then
  echo "Skipping canonical-livepatch."
elif command -v snap >/dev/null 2>&1; then
  if snap list canonical-livepatch >/dev/null 2>&1; then
    echo "canonical-livepatch already installed."
  else
    run_cmd snap install canonical-livepatch
  fi
  echo "Livepatch install is complete. Enabling it still requires an Ubuntu Pro token:"
  echo "  sudo canonical-livepatch enable <token>"
else
  echo "snap is not installed; skipping canonical-livepatch install."
fi

print_section "Stack Updates"
if [ "${SKIP_STACK_UPDATES}" = "1" ]; then
  echo "Skipping stack updates."
else
  if command -v npm >/dev/null 2>&1 && [ -n "${NPM_PROJECT_ROOTS}" ]; then
    mapfile -t npm_dirs < <(discover_npm_project_dirs "${NPM_PROJECT_ROOTS}")
    if [ "${#npm_dirs[@]}" -eq 0 ]; then
      echo "No Node projects found under: ${NPM_PROJECT_ROOTS}"
    fi
    for dir in "${npm_dirs[@]}"; do
      if [ -f "${dir}/package.json" ]; then
        run_in_dir "${dir}" npm audit fix
      else
        echo "Skipping npm audit fix; no package.json in ${dir}"
      fi
    done
  else
    echo "No npm project roots configured, or npm is not installed."
  fi

  if command -v docker >/dev/null 2>&1; then
    if [ -n "${COMPOSE_DIRS}" ]; then
      IFS=',' read -r -a compose_dirs <<<"${COMPOSE_DIRS}"
      for dir in "${compose_dirs[@]}"; do
        dir="$(trim_space "${dir}")"
        dir="$(expand_remote_path "${dir}")"
        if [ -f "${dir}/docker-compose.yml" ] || [ -f "${dir}/docker-compose.yaml" ] || [ -f "${dir}/compose.yml" ] || [ -f "${dir}/compose.yaml" ]; then
          run_in_dir "${dir}" docker compose pull
          run_in_dir "${dir}" docker compose up -d --remove-orphans
        else
          echo "Skipping docker compose; no compose file in ${dir}"
        fi
      done
    else
      mapfile -t images < <(run_priv docker ps --format '{{.Image}}' 2>/dev/null | sort -u || true)
      for image in "${images[@]}"; do
        run_cmd docker pull "${image}"
      done
      if [ "${#images[@]}" -eq 0 ]; then
        echo "No running Docker images found."
      else
        echo "Pulled running Docker images. Pass --compose-dirs to redeploy compose stacks."
      fi
    fi
  else
    echo "Docker is not installed."
  fi

  if command -v cloudflared >/dev/null 2>&1; then
    run_cmd cloudflared update
  else
    echo "cloudflared is not installed."
  fi

  if command -v tailscale >/dev/null 2>&1; then
    run_cmd tailscale update
  else
    echo "tailscale is not installed."
  fi
fi

print_section "Apply Current OS Updates"
run_cmd apt-get full-upgrade -y
run_cmd apt-get autoremove --purge -y
run_cmd apt-get autoclean -y

print_health_summary
echo "Completed patching and hardening run."
REMOTE_SCRIPT
