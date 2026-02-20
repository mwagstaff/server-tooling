#!/usr/bin/env zsh
set -euo pipefail

# Audit a remote Oracle Cloud host for package updates, Docker image freshness,
# and baseline hardening posture.
#
# Usage:
#   ./monitoring/check-security-updates.zsh [HOST_ALIAS]
# Examples:
#   ./monitoring/check-security-updates.zsh
#   TARGET_HOST=prod-oci ./monitoring/check-security-updates.zsh

TARGET_HOST="${1:-${TARGET_HOST:-ocl}}"

echo "==> Running update + security audit on: ${TARGET_HOST}"
echo

ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET_HOST}" "bash -s" <<'REMOTE_SCRIPT'
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

declare -a RECOMMENDATIONS=()
add_recommendation() {
  RECOMMENDATIONS+=("$1")
}

PACKAGE_MANAGER="unknown"
PACKAGE_UPDATES=0
SECURITY_UPDATES=0
DOCKER_IMAGE_UPDATES=0
REBOOT_REQUIRED=0

print_section "Host Information"
HOSTNAME_VALUE="$(hostname -f 2>/dev/null || hostname)"
KERNEL_VALUE="$(uname -r)"
OS_VALUE="Unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_VALUE="${PRETTY_NAME:-Unknown}"
fi
echo "Host: ${HOSTNAME_VALUE}"
echo "OS: ${OS_VALUE}"
echo "Kernel: ${KERNEL_VALUE}"
echo "Audit time (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if command -v apt-get >/dev/null 2>&1; then
  PACKAGE_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
  PACKAGE_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PACKAGE_MANAGER="yum"
elif command -v zypper >/dev/null 2>&1; then
  PACKAGE_MANAGER="zypper"
fi

check_apt() {
  print_section "Package Updates (APT)"
  run_priv apt-get update -y >/dev/null

  mapfile -t UPGRADABLE_PKGS < <(apt list --upgradable 2>/dev/null | sed '1d')
  PACKAGE_UPDATES="${#UPGRADABLE_PKGS[@]}"
  SECURITY_UPDATES=0

  for pkg in "${UPGRADABLE_PKGS[@]}"; do
    if [[ "${pkg}" == *"-security"* ]]; then
      SECURITY_UPDATES=$((SECURITY_UPDATES + 1))
    fi
  done

  echo "Upgradable packages: ${PACKAGE_UPDATES}"
  echo "Likely security updates: ${SECURITY_UPDATES}"

  if [ "${PACKAGE_UPDATES}" -gt 0 ]; then
    echo
    echo "Top pending updates:"
    limit=40
    for ((i = 0; i < PACKAGE_UPDATES && i < limit; i++)); do
      echo "  - ${UPGRADABLE_PKGS[$i]}"
    done
    if [ "${PACKAGE_UPDATES}" -gt "${limit}" ]; then
      echo "  - ... and $((PACKAGE_UPDATES - limit)) more"
    fi

    add_recommendation "Apply OS updates: sudo apt-get upgrade -y && sudo apt-get full-upgrade -y"
  else
    echo "No package updates pending."
  fi

  if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    UA_ENABLED="$(run_priv systemctl is-enabled unattended-upgrades 2>/dev/null || true)"
    UA_ACTIVE="$(run_priv systemctl is-active unattended-upgrades 2>/dev/null || true)"
    echo "unattended-upgrades installed: yes (enabled=${UA_ENABLED:-unknown}, active=${UA_ACTIVE:-unknown})"
    if [ "${UA_ENABLED:-}" != "enabled" ]; then
      add_recommendation "Enable automatic security updates: sudo systemctl enable --now unattended-upgrades"
    fi
  else
    echo "unattended-upgrades installed: no"
    add_recommendation "Install automatic security updates: sudo apt-get install -y unattended-upgrades"
  fi
}

check_dnf_family() {
  local PM="$1"
  print_section "Package Updates (${PM^^})"

  set +e
  CHECK_OUTPUT="$(run_priv "${PM}" check-update --refresh 2>&1)"
  CHECK_RC=$?
  set -e

  if [ "${CHECK_RC}" -eq 0 ]; then
    PACKAGE_UPDATES=0
    echo "No package updates pending."
  elif [ "${CHECK_RC}" -eq 100 ]; then
    mapfile -t UPDATE_LINES < <(printf "%s\n" "${CHECK_OUTPUT}" | awk 'NF>=3 && $1 !~ /^Last/ && $1 !~ /^Obsoleting/ && $1 !~ /^Security:/')
    PACKAGE_UPDATES="${#UPDATE_LINES[@]}"
    echo "Upgradable packages: ${PACKAGE_UPDATES}"
    if [ "${PACKAGE_UPDATES}" -gt 0 ]; then
      limit=40
      echo
      echo "Top pending updates:"
      for ((i = 0; i < PACKAGE_UPDATES && i < limit; i++)); do
        echo "  - ${UPDATE_LINES[$i]}"
      done
      if [ "${PACKAGE_UPDATES}" -gt "${limit}" ]; then
        echo "  - ... and $((PACKAGE_UPDATES - limit)) more"
      fi
      add_recommendation "Apply OS updates: sudo ${PM} upgrade -y"
    fi
  else
    echo "Unable to check ${PM} updates."
    echo "${CHECK_OUTPUT}"
    add_recommendation "Manually verify ${PM} repositories and rerun '${PM} check-update'."
  fi

  set +e
  SECURITY_OUTPUT="$(run_priv "${PM}" updateinfo list security 2>/dev/null)"
  SECURITY_RC=$?
  set -e

  if [ "${SECURITY_RC}" -eq 0 ]; then
    mapfile -t SECURITY_LINES < <(printf "%s\n" "${SECURITY_OUTPUT}" | awk 'NF>=3 && $1 !~ /^Last/')
    SECURITY_UPDATES="${#SECURITY_LINES[@]}"
  else
    SECURITY_UPDATES=0
  fi
  echo "Security advisories available: ${SECURITY_UPDATES}"
}

check_zypper() {
  print_section "Package Updates (ZYPPER)"
  run_priv zypper --non-interactive refresh >/dev/null

  set +e
  ZYPPER_OUTPUT="$(run_priv zypper --non-interactive list-updates 2>&1)"
  ZYPPER_RC=$?
  set -e

  if [ "${ZYPPER_RC}" -ne 0 ]; then
    echo "Unable to check zypper updates."
    echo "${ZYPPER_OUTPUT}"
    add_recommendation "Manually verify zypper repositories and rerun 'zypper list-updates'."
    return
  fi

  mapfile -t ZUPDATES < <(printf "%s\n" "${ZYPPER_OUTPUT}" | awk -F'|' '/^\|/ && $2 !~ /Repository|---/ {gsub(/^ +| +$/,"",$2); if($2!="") print $0}')
  PACKAGE_UPDATES="${#ZUPDATES[@]}"
  echo "Upgradable packages: ${PACKAGE_UPDATES}"
  echo "Security-specific counts are distro-specific on zypper (manual advisory review recommended)."

  if [ "${PACKAGE_UPDATES}" -gt 0 ]; then
    limit=40
    echo
    echo "Top pending updates:"
    for ((i = 0; i < PACKAGE_UPDATES && i < limit; i++)); do
      echo "  - ${ZUPDATES[$i]}"
    done
    if [ "${PACKAGE_UPDATES}" -gt "${limit}" ]; then
      echo "  - ... and $((PACKAGE_UPDATES - limit)) more"
    fi
    add_recommendation "Apply OS updates: sudo zypper --non-interactive update"
  fi
}

check_docker() {
  print_section "Docker Container + Image Updates"

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not installed."
    return
  fi

  if ! run_priv docker info >/dev/null 2>&1; then
    echo "Docker installed but daemon is not reachable."
    add_recommendation "Start Docker daemon: sudo systemctl enable --now docker"
    return
  fi

  mapfile -t CONTAINERS < <(run_priv docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
  local_count="${#CONTAINERS[@]}"
  echo "Containers discovered: ${local_count}"

  if [ "${local_count}" -eq 0 ]; then
    echo "No containers found."
    return
  fi

  echo
  echo "Current containers:"
  for item in "${CONTAINERS[@]}"; do
    IFS='|' read -r cname cimage cstatus <<<"${item}"
    echo "  - ${cname}: ${cimage} (${cstatus})"
  done

  mapfile -t UNIQUE_IMAGES < <(run_priv docker ps -a --format '{{.Image}}' | sort -u)
  echo
  echo "Checking image freshness via docker pull..."
  DOCKER_IMAGE_UPDATES=0

  for image in "${UNIQUE_IMAGES[@]}"; do
    [ -z "${image}" ] && continue
    before_id="$(run_priv docker image inspect "${image}" --format '{{.Id}}' 2>/dev/null || true)"

    set +e
    pull_out="$(run_priv docker pull "${image}" 2>&1)"
    pull_rc=$?
    set -e

    if [ "${pull_rc}" -ne 0 ]; then
      last_line="$(printf "%s\n" "${pull_out}" | sed -n '$p')"
      echo "  - ${image}: could not check (${last_line})"
      add_recommendation "Verify registry access for '${image}' and update manually if needed."
      continue
    fi

    after_id="$(run_priv docker image inspect "${image}" --format '{{.Id}}' 2>/dev/null || true)"
    if [ -n "${before_id}" ] && [ -n "${after_id}" ] && [ "${before_id}" != "${after_id}" ]; then
      DOCKER_IMAGE_UPDATES=$((DOCKER_IMAGE_UPDATES + 1))
      echo "  - ${image}: update pulled (container restart/redeploy required)"
    else
      echo "  - ${image}: already up to date"
    fi
  done

  echo "Images with new versions available: ${DOCKER_IMAGE_UPDATES}"
  if [ "${DOCKER_IMAGE_UPDATES}" -gt 0 ]; then
    add_recommendation "Redeploy containers so they use updated images: docker compose pull && docker compose up -d"
  fi

  dangling_count="$(run_priv docker images -f dangling=true -q | wc -l | tr -d ' ')"
  echo "Dangling images: ${dangling_count}"
  if [ "${dangling_count}" -gt 0 ]; then
    add_recommendation "Prune old dangling Docker images: docker image prune -f"
  fi

  if command -v trivy >/dev/null 2>&1; then
    echo "Container CVE scanner detected: trivy"
    add_recommendation "Run container vulnerability scans: trivy image --severity HIGH,CRITICAL <image>"
  elif run_priv docker scout version >/dev/null 2>&1; then
    echo "Container CVE scanner detected: docker scout"
    add_recommendation "Run container vulnerability scans: docker scout quickview <image>"
  else
    echo "No container vulnerability scanner found (trivy/docker scout)."
    add_recommendation "Install Trivy or Docker Scout for continuous image CVE checks."
  fi
}

check_hardening() {
  print_section "Hardening Checks"

  if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=1
    echo "Reboot required: yes"
    add_recommendation "Reboot host after patching to load updated kernel/libraries."
  else
    echo "Reboot required: no"
  fi

  if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS="$(run_priv ufw status 2>/dev/null | sed -n '1p' || true)"
    echo "Firewall (ufw): ${UFW_STATUS:-unknown}"
    if [[ "${UFW_STATUS:-}" != "Status: active" ]]; then
      add_recommendation "Enable firewall and restrict ingress: sudo ufw enable"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1; then
    FIREWALLD_STATE="$(run_priv firewall-cmd --state 2>/dev/null || true)"
    echo "Firewall (firewalld): ${FIREWALLD_STATE:-unknown}"
    if [ "${FIREWALLD_STATE:-}" != "running" ]; then
      add_recommendation "Enable firewall service: sudo systemctl enable --now firewalld"
    fi
  else
    echo "Firewall tooling not detected (ufw/firewalld)."
    add_recommendation "Install and enable a host firewall (ufw or firewalld)."
  fi

  if command -v fail2ban-client >/dev/null 2>&1; then
    F2B_STATE="$(run_priv systemctl is-active fail2ban 2>/dev/null || true)"
    echo "fail2ban: ${F2B_STATE:-unknown}"
    if [ "${F2B_STATE:-}" != "active" ]; then
      add_recommendation "Enable brute-force protection: sudo systemctl enable --now fail2ban"
    fi
  else
    echo "fail2ban: not installed"
    add_recommendation "Install fail2ban to protect SSH and internet-facing services."
  fi

  SSHD_TEST="$(run_priv sshd -T 2>/dev/null || true)"
  PERMIT_ROOT_LOGIN="$(printf "%s\n" "${SSHD_TEST}" | awk '$1=="permitrootlogin" {print $2; exit}')"
  PASSWORD_AUTH="$(printf "%s\n" "${SSHD_TEST}" | awk '$1=="passwordauthentication" {print $2; exit}')"
  [ -z "${PERMIT_ROOT_LOGIN}" ] && PERMIT_ROOT_LOGIN="unknown"
  [ -z "${PASSWORD_AUTH}" ] && PASSWORD_AUTH="unknown"

  echo "SSH PermitRootLogin: ${PERMIT_ROOT_LOGIN}"
  echo "SSH PasswordAuthentication: ${PASSWORD_AUTH}"

  if [ "${PERMIT_ROOT_LOGIN}" != "no" ] && [ "${PERMIT_ROOT_LOGIN}" != "prohibit-password" ]; then
    add_recommendation "Disable direct root SSH login in /etc/ssh/sshd_config (PermitRootLogin no)."
  fi
  if [ "${PASSWORD_AUTH}" != "no" ]; then
    add_recommendation "Disable SSH password auth and require keys (PasswordAuthentication no)."
  fi
}

case "${PACKAGE_MANAGER}" in
  apt)
    check_apt
    ;;
  dnf)
    check_dnf_family "dnf"
    ;;
  yum)
    check_dnf_family "yum"
    ;;
  zypper)
    check_zypper
    ;;
  *)
    print_section "Package Updates"
    echo "No supported package manager detected (apt/dnf/yum/zypper)."
    add_recommendation "Install a supported package manager or run manual update checks."
    ;;
esac

check_docker
check_hardening

print_section "Summary"
echo "Package manager: ${PACKAGE_MANAGER}"
echo "Pending package updates: ${PACKAGE_UPDATES}"
echo "Pending security updates/advisories: ${SECURITY_UPDATES}"
echo "Docker images with updates available: ${DOCKER_IMAGE_UPDATES}"
echo "Reboot required: ${REBOOT_REQUIRED}"

if [ "${#RECOMMENDATIONS[@]}" -gt 0 ]; then
  echo
  echo "Recommended next actions:"
  for rec in "${RECOMMENDATIONS[@]}"; do
    echo "  - ${rec}"
  done
else
  echo
  echo "No immediate recommendations found."
fi
REMOTE_SCRIPT

echo
echo "==> Audit complete for ${TARGET_HOST}"
