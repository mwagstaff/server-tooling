#!/usr/bin/env bash
set -euo pipefail

# One-click hardening for an Ubuntu Oracle Cloud host.
# - Installs Trivy (and optional Docker Scout plugin)
# - Optionally applies UFW firewall hardening (opt-in)
# - Installs/configures fail2ban
# - Installs/enables auditd
# - Disables direct root SSH login
# - Ensures unattended-upgrades is enabled
#
# Usage:
#   ./monitoring/harden_server.sh [HOST_ALIAS] [OPTIONS]
#
# Examples:
#   ./monitoring/harden_server.sh ocl
#   ./monitoring/harden_server.sh ocl --dry-run
#   ./monitoring/harden_server.sh ocl --apply-firewall-hardening --allow-ports 22,80,443
#   ./monitoring/harden_server.sh ocl --apply-firewall-hardening --force-netfilter-replace

TARGET_HOST="${TARGET_HOST:-ocl}"
ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-22,80,443}"
DRY_RUN=0
INSTALL_DOCKER_SCOUT=0
SKIP_SSH_HARDENING=0
LOCK_SSH_TO_CLIENT_IP=0
FORCE_NETFILTER_REPLACE=0
COLOR_DIFF=1
APPLY_FIREWALL_HARDENING=0

usage() {
  cat <<'EOF'
Usage:
  ./monitoring/harden_server.sh [HOST_ALIAS] [OPTIONS]

Options:
  --dry-run               Show planned changes only
  --apply-firewall-hardening Explicitly apply UFW firewall changes (default: skip)
  --allow-ports PORTS     Comma-separated inbound TCP ports to allow with UFW (default: 22,80,443)
  --install-docker-scout  Attempt to install docker-scout-plugin
  --skip-ssh-hardening    Do not edit SSH configuration
  --lock-ssh-to-client-ip Allow SSH only from current client public IP (UFW mode)
  --force-netfilter-replace Proceed even if iptables-persistent has custom rules (UFW mode)
  --no-color-diff         Disable colored diff output
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-ports)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --allow-ports" >&2
        exit 1
      fi
      ALLOW_TCP_PORTS="$2"
      shift 2
      ;;
    --apply-firewall-hardening)
      APPLY_FIREWALL_HARDENING=1
      shift
      ;;
    --install-docker-scout)
      INSTALL_DOCKER_SCOUT=1
      shift
      ;;
    --skip-ssh-hardening)
      SKIP_SSH_HARDENING=1
      shift
      ;;
    --lock-ssh-to-client-ip)
      LOCK_SSH_TO_CLIENT_IP=1
      shift
      ;;
    --force-netfilter-replace)
      FORCE_NETFILTER_REPLACE=1
      shift
      ;;
    --no-color-diff)
      COLOR_DIFF=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      TARGET_HOST="$1"
      shift
      ;;
  esac
done

echo "==> Hardening host: ${TARGET_HOST}"
echo "==> dry_run=${DRY_RUN} apply_firewall_hardening=${APPLY_FIREWALL_HARDENING} allow_ports=${ALLOW_TCP_PORTS} install_docker_scout=${INSTALL_DOCKER_SCOUT} skip_ssh_hardening=${SKIP_SSH_HARDENING} lock_ssh_to_client_ip=${LOCK_SSH_TO_CLIENT_IP} force_netfilter_replace=${FORCE_NETFILTER_REPLACE} color_diff=${COLOR_DIFF}"
echo

ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET_HOST}" \
  "ALLOW_TCP_PORTS=${ALLOW_TCP_PORTS} DRY_RUN=${DRY_RUN} INSTALL_DOCKER_SCOUT=${INSTALL_DOCKER_SCOUT} SKIP_SSH_HARDENING=${SKIP_SSH_HARDENING} LOCK_SSH_TO_CLIENT_IP=${LOCK_SSH_TO_CLIENT_IP} FORCE_NETFILTER_REPLACE=${FORCE_NETFILTER_REPLACE} COLOR_DIFF=${COLOR_DIFF} APPLY_FIREWALL_HARDENING=${APPLY_FIREWALL_HARDENING} bash -s" <<'REMOTE_SCRIPT'
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

run_shell() {
  local cmd="$1"
  if [ "${DRY_RUN}" = "1" ]; then
    echo "[dry-run] ${cmd}"
  else
    run_priv bash -lc "${cmd}"
  fi
}

ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-22,80,443}"
DRY_RUN="${DRY_RUN:-0}"
INSTALL_DOCKER_SCOUT="${INSTALL_DOCKER_SCOUT:-0}"
SKIP_SSH_HARDENING="${SKIP_SSH_HARDENING:-0}"
LOCK_SSH_TO_CLIENT_IP="${LOCK_SSH_TO_CLIENT_IP:-0}"
FORCE_NETFILTER_REPLACE="${FORCE_NETFILTER_REPLACE:-0}"
COLOR_DIFF="${COLOR_DIFF:-1}"
APPLY_FIREWALL_HARDENING="${APPLY_FIREWALL_HARDENING:-0}"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script currently supports Ubuntu/Debian (apt) hosts only." >&2
  exit 1
fi

DIST_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
if [[ -z "${DIST_CODENAME}" ]]; then
  DIST_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
fi
if [[ -z "${DIST_CODENAME}" ]]; then
  echo "Unable to determine distro codename for apt repositories." >&2
  exit 1
fi

if [ "${APPLY_FIREWALL_HARDENING}" != "1" ]; then
  if [ "${LOCK_SSH_TO_CLIENT_IP}" = "1" ] || [ "${FORCE_NETFILTER_REPLACE}" = "1" ]; then
    print_section "Firewall Flags Ignored"
    echo "--lock-ssh-to-client-ip/--force-netfilter-replace only apply with --apply-firewall-hardening."
  fi
fi

# If a previous run wrote a malformed Trivy repo entry (literal $(lsb_release ...)),
# clean it before the first apt-get update.
if [ -f /etc/apt/sources.list.d/trivy.list ] && grep -Fq '$(' /etc/apt/sources.list.d/trivy.list; then
  echo "Detected malformed Trivy apt source; removing /etc/apt/sources.list.d/trivy.list"
  run_shell "rm -f /etc/apt/sources.list.d/trivy.list"
fi

render_current_firewall_snapshot() {
  local out_file="$1"
  {
    echo "FIREWALL_BACKEND=iptables-persistent"
    for rules_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
      echo
      echo "### ${rules_file}"
      if [ -f "${rules_file}" ]; then
        run_priv cat "${rules_file}" || true
      else
        echo "(missing)"
      fi
    done
  } >"${out_file}"
}

render_projected_firewall_snapshot() {
  local out_file="$1"

  mapfile -t preview_ssh_ports < <(run_priv sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -u)
  if [ "${#preview_ssh_ports[@]}" -eq 0 ]; then
    preview_ssh_ports=(22)
  fi
  preview_ssh_client_ip="$(printf "%s\n" "${SSH_CONNECTION:-}" | awk '{print $1}')"

  declare -A preview_allow_ports=()
  {
    echo "FIREWALL_BACKEND=ufw"
    echo "DEFAULT_INCOMING=deny"
    echo "DEFAULT_OUTGOING=allow"
    echo "SSH_PORTS=$(IFS=,; echo "${preview_ssh_ports[*]}")"

    if [ "${LOCK_SSH_TO_CLIENT_IP}" = "1" ]; then
      if [[ -n "${preview_ssh_client_ip}" ]]; then
        for p in "${preview_ssh_ports[@]}"; do
          echo "ALLOW from ${preview_ssh_client_ip} to any port ${p}/tcp"
        done
      else
        echo "ALLOW (error): --lock-ssh-to-client-ip requested but current client IP is unavailable"
      fi
    else
      for p in "${preview_ssh_ports[@]}"; do
        preview_allow_ports["${p}"]=1
      done
    fi

    IFS=',' read -r -a preview_extra_ports <<<"${ALLOW_TCP_PORTS}"
    for p in "${preview_extra_ports[@]}"; do
      trimmed="$(echo "${p}" | xargs)"
      if [[ -n "${trimmed}" && "${trimmed}" =~ ^[0-9]+$ ]]; then
        if [ "${LOCK_SSH_TO_CLIENT_IP}" = "1" ]; then
          skip_ssh_port=0
          for sshp in "${preview_ssh_ports[@]}"; do
            if [ "${trimmed}" = "${sshp}" ]; then
              skip_ssh_port=1
              break
            fi
          done
          if [ "${skip_ssh_port}" -eq 1 ]; then
            continue
          fi
        fi
        preview_allow_ports["${trimmed}"]=1
      fi
    done

    if [ "${#preview_allow_ports[@]}" -gt 0 ]; then
      while IFS= read -r port; do
        [ -n "${port}" ] && echo "ALLOW ${port}/tcp"
      done < <(printf '%s\n' "${!preview_allow_ports[@]}" | sort -n)
    fi
  } >"${out_file}"
}

discover_ssh_context() {
  mapfile -t ssh_ports < <(run_priv sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -u)
  if [ "${#ssh_ports[@]}" -eq 0 ]; then
    ssh_ports=(22)
  fi
  ssh_ports_csv="$(IFS=,; echo "${ssh_ports[*]}")"
  ssh_client_ip="$(printf "%s\n" "${SSH_CONNECTION:-}" | awk '{print $1}')"
}

check_netfilter_replacement_risk() {
  print_section "Netfilter Persistence Check"

  has_netfilter_pkg=0
  if run_priv dpkg -s iptables-persistent >/dev/null 2>&1; then
    has_netfilter_pkg=1
  fi
  if run_priv dpkg -s netfilter-persistent >/dev/null 2>&1; then
    has_netfilter_pkg=1
  fi

  if [ "${has_netfilter_pkg}" -eq 0 ]; then
    echo "No iptables-persistent/netfilter-persistent packages detected."
    return
  fi

  echo "Detected installed netfilter persistence packages."
  echo "These may be removed when UFW is installed."

  custom_rules_detected=0
  for rules_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ -s "${rules_file}" ]; then
      echo "Found ${rules_file}"
      if grep -Eq '^-A[[:space:]]' "${rules_file}"; then
        custom_rules_detected=1
      fi
    fi
  done

  current_snapshot="$(mktemp)"
  projected_snapshot="$(mktemp)"
  render_current_firewall_snapshot "${current_snapshot}"
  render_projected_firewall_snapshot "${projected_snapshot}"

  echo
  echo "Projected firewall policy diff (current -> projected):"
  if command -v diff >/dev/null 2>&1; then
    if [ "${COLOR_DIFF}" = "1" ] && diff --help 2>/dev/null | grep -q -- '--color'; then
      if diff --color=always -u "${current_snapshot}" "${projected_snapshot}"; then
        echo "No changes detected between current and projected snapshots."
      fi
    elif [ "${COLOR_DIFF}" = "1" ] && command -v colordiff >/dev/null 2>&1; then
      if colordiff -u "${current_snapshot}" "${projected_snapshot}"; then
        echo "No changes detected between current and projected snapshots."
      fi
    else
      if diff -u "${current_snapshot}" "${projected_snapshot}"; then
        echo "No changes detected between current and projected snapshots."
      fi
    fi
  else
    echo "diff command not available; cannot render snapshot diff."
  fi
  echo

  rm -f "${current_snapshot}" "${projected_snapshot}"

  if [ "${DRY_RUN}" = "1" ]; then
    echo "Dry-run mode: no changes made."
    if [ "${custom_rules_detected}" -eq 1 ] && [ "${FORCE_NETFILTER_REPLACE}" != "1" ]; then
      echo "Would block apply run due to custom persistent iptables rules."
      echo "If intended, rerun with --force-netfilter-replace."
    fi
    return
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/netfilter-backups/${ts}"
  run_priv mkdir -p "${backup_dir}"
  for rules_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ -f "${rules_file}" ]; then
      run_priv cp -a "${rules_file}" "${backup_dir}/"
    fi
  done
  if command -v iptables-save >/dev/null 2>&1; then
    run_priv bash -lc "iptables-save > '${backup_dir}/iptables-save.txt'" || true
  fi
  if command -v ip6tables-save >/dev/null 2>&1; then
    run_priv bash -lc "ip6tables-save > '${backup_dir}/ip6tables-save.txt'" || true
  fi
  echo "Backed up existing netfilter config to: ${backup_dir}"

  if [ "${custom_rules_detected}" -eq 1 ] && [ "${FORCE_NETFILTER_REPLACE}" != "1" ]; then
    echo "Refusing to proceed: custom persistent iptables rules detected."
    echo "Review backup at ${backup_dir} and rerun with --force-netfilter-replace if migration is intended."
    exit 1
  fi

  if [ "${custom_rules_detected}" -eq 1 ]; then
    echo "Proceeding despite custom persistent rules because --force-netfilter-replace was provided."
  else
    echo "No custom persistent '-A' rules detected. Proceeding."
  fi
}

discover_ssh_context

if [ "${APPLY_FIREWALL_HARDENING}" = "1" ]; then
  print_section "Firewall Hardening Warning"
  echo "UFW hardening is explicitly enabled."
  echo "On OCI Ubuntu images this may replace Oracle-provided iptables persistence rules."
  echo "Oracle platform image guidance cautions that changing UFW rules can affect reboot behavior."
  echo "Review the diff below before proceeding."
  check_netfilter_replacement_risk
else
  print_section "Firewall (UFW)"
  echo "Skipped by default to preserve existing OCI netfilter/iptables behavior."
  echo "Configured allow_ports (${ALLOW_TCP_PORTS}) is ignored unless --apply-firewall-hardening is set."
  echo "To enable firewall changes explicitly, rerun with --apply-firewall-hardening."
fi

print_section "Base Security Packages"
run_cmd apt-get update -y
run_cmd env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
  ca-certificates curl gnupg lsb-release fail2ban unattended-upgrades auditd

print_section "Automatic Security Updates"
run_cmd systemctl enable --now unattended-upgrades

print_section "Audit Logging (auditd)"
run_cmd systemctl enable --now auditd

print_section "Trivy Installation"
if command -v trivy >/dev/null 2>&1; then
  echo "Trivy already installed: $(trivy --version | head -n1)"
else
  # Repair any previous bad repo line before apt update.
  run_shell "rm -f /etc/apt/sources.list.d/trivy.list"
  run_shell "install -m 0755 -d /usr/share/keyrings"
  run_shell "curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/trivy.gpg"
  run_shell "printf '%s\n' 'deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb ${DIST_CODENAME} main' > /etc/apt/sources.list.d/trivy.list"
  run_cmd apt-get update -y
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y trivy
fi

if [ "${INSTALL_DOCKER_SCOUT}" = "1" ]; then
  print_section "Docker Scout Installation"
  if apt-cache show docker-scout-plugin >/dev/null 2>&1; then
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-scout-plugin
  else
    echo "docker-scout-plugin package not available in configured apt repositories."
  fi
fi

if [ "${APPLY_FIREWALL_HARDENING}" = "1" ]; then
  print_section "Firewall (UFW)"
  echo "SSH port(s) detected: ${ssh_ports_csv}"
  if [[ -n "${ssh_client_ip}" ]]; then
    echo "Current SSH client IP: ${ssh_client_ip}"
  fi

  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
  run_cmd ufw default deny incoming
  run_cmd ufw default allow outgoing

  declare -A ufw_allow_ports=()

  if [ "${LOCK_SSH_TO_CLIENT_IP}" = "1" ]; then
    if [[ -z "${ssh_client_ip}" ]]; then
      echo "Cannot determine SSH client IP; refusing strict SSH lock mode." >&2
      exit 1
    fi
    for p in "${ssh_ports[@]}"; do
      run_cmd ufw allow from "${ssh_client_ip}" to any port "${p}" proto tcp
    done
  else
    for p in "${ssh_ports[@]}"; do
      ufw_allow_ports["${p}"]=1
    done
  fi

  IFS=',' read -r -a extra_ports <<<"${ALLOW_TCP_PORTS}"
  for p in "${extra_ports[@]}"; do
    trimmed="$(echo "${p}" | xargs)"
    if [[ -n "${trimmed}" && "${trimmed}" =~ ^[0-9]+$ ]]; then
      if [ "${LOCK_SSH_TO_CLIENT_IP}" = "1" ]; then
        skip_ssh_port=0
        for sshp in "${ssh_ports[@]}"; do
          if [ "${trimmed}" = "${sshp}" ]; then
            skip_ssh_port=1
            break
          fi
        done
        if [ "${skip_ssh_port}" -eq 1 ]; then
          echo "Skipping broad allow for SSH port ${trimmed} because --lock-ssh-to-client-ip is enabled."
          continue
        fi
      fi
      ufw_allow_ports["${trimmed}"]=1
    fi
  done

  for port in "${!ufw_allow_ports[@]}"; do
    run_cmd ufw allow "${port}/tcp"
  done

  run_cmd ufw --force enable
fi

print_section "fail2ban"
if [ "${DRY_RUN}" = "1" ]; then
  echo "[dry-run] write /etc/fail2ban/jail.d/sshd-hardening.conf"
else
  ignoreip_line="ignoreip = 127.0.0.1/8 ::1"
  if [[ -n "${ssh_client_ip}" ]]; then
    ignoreip_line="${ignoreip_line} ${ssh_client_ip}"
  fi
  run_shell "cat >/etc/fail2ban/jail.d/sshd-hardening.conf <<'EOF'
[sshd]
enabled = true
port = ${ssh_ports_csv}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
${ignoreip_line}
EOF"
fi
run_cmd systemctl enable --now fail2ban
run_cmd systemctl restart fail2ban

if [ "${SKIP_SSH_HARDENING}" != "1" ]; then
  print_section "SSH Hardening"
  if [ "${DRY_RUN}" = "1" ]; then
    echo "[dry-run] write /etc/ssh/sshd_config.d/99-hardening.conf with root/password login disabled and key auth enforced"
    echo "[dry-run] validate sshd config and restart ssh service"
  else
    run_shell "cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF"
    run_priv sshd -t

    if systemctl list-unit-files | grep -q '^ssh.service'; then
      run_priv systemctl restart ssh
    else
      run_priv systemctl restart sshd
    fi
  fi
else
  print_section "SSH Hardening"
  echo "Skipped by request."
fi

print_section "Verification"
if [ "${DRY_RUN}" = "1" ]; then
  echo "Dry-run complete. No changes were applied."
  exit 0
fi

echo "UFW:"
if [ "${APPLY_FIREWALL_HARDENING}" = "1" ]; then
  run_priv ufw status | sed -n '1,20p'
else
  echo "Skipped (firewall hardening not requested)."
fi

echo
echo "fail2ban:"
run_priv fail2ban-client status sshd || true

echo
echo "auditd:"
run_priv systemctl is-enabled auditd 2>/dev/null || true
run_priv systemctl is-active auditd 2>/dev/null || true

echo
echo "SSH settings:"
run_priv sshd -T | awk '$1=="permitrootlogin" || $1=="passwordauthentication" || $1=="kbdinteractiveauthentication" || $1=="pubkeyauthentication" || $1=="port"'

echo
echo "authorized_keys review:"
found_keys=0
for key_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  if [ -f "${key_file}" ]; then
    found_keys=1
    key_count="$(run_priv wc -l < "${key_file}" | tr -d ' ')"
    echo "  - ${key_file}: ${key_count} key(s)"
  fi
done
if [ "${found_keys}" -eq 0 ]; then
  echo "  - No authorized_keys files found in /root or /home/*."
fi

echo
if command -v trivy >/dev/null 2>&1; then
  echo "Trivy: $(trivy --version | head -n1)"
fi

echo "unattended-upgrades: $(run_priv systemctl is-enabled unattended-upgrades 2>/dev/null || true)"

echo
print_section "OCI Manual Follow-Ups"
echo "- Enable OCI Vulnerability Scanning Service host scanning for this instance."
echo "- Enable Cloud Guard for the compartment/tenancy and review detector findings."
echo "- Review IAM policies for least privilege and minimize delete permissions."
echo "- Verify boot volume uses customer-managed keys if required by your policy."
REMOTE_SCRIPT

echo
echo "==> Hardening completed for ${TARGET_HOST}"
