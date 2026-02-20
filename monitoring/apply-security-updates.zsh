#!/usr/bin/env zsh
set -euo pipefail

# Apply OS and container updates on a remote host.
#
# Usage:
#   ./monitoring/apply-security-updates.zsh [HOST_ALIAS] [OPTIONS]
#
# Options:
#   --dry-run            Show what would run, but do not apply changes
#   --reboot             Reboot automatically if required after patching
#   --skip-docker        Skip Docker image pull + compose redeploy
#   --enable-ufw         Install/enable UFW and allow active SSH port(s)
#   --install-fail2ban   Install and enable fail2ban
#   --metrics-dir DIR    Remote directory for metrics outputs
#   --prom-file PATH     Remote Prometheus textfile path
#   --json-file PATH     Remote JSON status file path
#   -h, --help           Show help

TARGET_HOST="${TARGET_HOST:-ocl}"
DRY_RUN=0
AUTO_REBOOT=0
SKIP_DOCKER=0
ENABLE_UFW=0
INSTALL_FAIL2BAN=0
METRICS_DIR="${METRICS_DIR:-/var/lib/server-tooling/metrics}"
PROM_FILE="${PROM_FILE:-/var/lib/server-tooling/metrics/security_updates.prom}"
JSON_FILE="${JSON_FILE:-/var/lib/server-tooling/metrics/security_updates.json}"

usage() {
  cat <<'EOF'
Usage:
  ./monitoring/apply-security-updates.zsh [HOST_ALIAS] [OPTIONS]

Examples:
  ./monitoring/apply-security-updates.zsh ocl
  ./monitoring/apply-security-updates.zsh ocl --dry-run
  ./monitoring/apply-security-updates.zsh prod --reboot --enable-ufw --install-fail2ban

Options:
  --dry-run            Show planned changes only
  --reboot             Reboot automatically if required
  --skip-docker        Skip Docker refresh/redeploy
  --enable-ufw         Install/enable UFW and allow active SSH port(s)
  --install-fail2ban   Install and enable fail2ban
  --metrics-dir DIR    Remote directory for metrics outputs
  --prom-file PATH     Remote Prometheus textfile path
  --json-file PATH     Remote JSON status file path
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --reboot)
      AUTO_REBOOT=1
      shift
      ;;
    --skip-docker)
      SKIP_DOCKER=1
      shift
      ;;
    --enable-ufw)
      ENABLE_UFW=1
      shift
      ;;
    --install-fail2ban)
      INSTALL_FAIL2BAN=1
      shift
      ;;
    --metrics-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --metrics-dir" >&2
        exit 1
      fi
      METRICS_DIR="$2"
      shift 2
      ;;
    --prom-file)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --prom-file" >&2
        exit 1
      fi
      PROM_FILE="$2"
      shift 2
      ;;
    --json-file)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --json-file" >&2
        exit 1
      fi
      JSON_FILE="$2"
      shift 2
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

echo "==> Applying updates on host: ${TARGET_HOST}"
echo "==> dry_run=${DRY_RUN} reboot=${AUTO_REBOOT} skip_docker=${SKIP_DOCKER} enable_ufw=${ENABLE_UFW} install_fail2ban=${INSTALL_FAIL2BAN}"
echo "==> metrics_dir=${METRICS_DIR}"
echo "==> prom_file=${PROM_FILE}"
echo "==> json_file=${JSON_FILE}"
echo

ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET_HOST}" \
  "DRY_RUN=${DRY_RUN} AUTO_REBOOT=${AUTO_REBOOT} SKIP_DOCKER=${SKIP_DOCKER} ENABLE_UFW=${ENABLE_UFW} INSTALL_FAIL2BAN=${INSTALL_FAIL2BAN} METRICS_DIR=${METRICS_DIR} PROM_FILE=${PROM_FILE} JSON_FILE=${JSON_FILE} bash -s" <<'REMOTE_SCRIPT'
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

DRY_RUN="${DRY_RUN:-0}"
AUTO_REBOOT="${AUTO_REBOOT:-0}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"
ENABLE_UFW="${ENABLE_UFW:-0}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-0}"
METRICS_DIR="${METRICS_DIR:-/var/lib/server-tooling/metrics}"
PROM_FILE="${PROM_FILE:-/var/lib/server-tooling/metrics/security_updates.prom}"
JSON_FILE="${JSON_FILE:-/var/lib/server-tooling/metrics/security_updates.json}"

RUN_TS_EPOCH="$(date -u +%s)"
RUN_TS_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOST_NAME="$(hostname -f 2>/dev/null || hostname)"
VULN_PATCHES_APPLIED=-1
VULN_PATCH_COUNT_SUPPORTED=0
PENDING_PACKAGE_UPDATES_AFTER=-1
REBOOT_REQUIRED=0

PACKAGE_MANAGER="unknown"
if command -v apt-get >/dev/null 2>&1; then
  PACKAGE_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
  PACKAGE_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PACKAGE_MANAGER="yum"
elif command -v zypper >/dev/null 2>&1; then
  PACKAGE_MANAGER="zypper"
fi

print_section "Host Information"
echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Audit time (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Package manager: ${PACKAGE_MANAGER}"

if [ "${PACKAGE_MANAGER}" = "unknown" ]; then
  echo "No supported package manager detected (apt/dnf/yum/zypper)." >&2
  exit 1
fi

count_apt_security_updates() {
  apt list --upgradable 2>/dev/null | sed '1d' | grep -c -- '-security' || true
}

count_dnf_security_advisories() {
  local pm="$1"
  local out
  set +e
  out="$(run_priv "${pm}" updateinfo list security 2>/dev/null)"
  local rc=$?
  set -e
  if [ "${rc}" -ne 0 ]; then
    echo "-1"
    return
  fi
  printf "%s\n" "${out}" | awk 'NF>=3 && $1 !~ /^Last/ {c++} END{print c+0}'
}

apply_os_updates() {
  print_section "OS Updates"

  case "${PACKAGE_MANAGER}" in
    apt)
      run_priv apt-get update -y >/dev/null
      security_before="$(count_apt_security_updates)"
      before_count="$(apt list --upgradable 2>/dev/null | sed '1d' | wc -l | tr -d ' ')"
      echo "Pending package updates before patching: ${before_count}"
      echo "Security updates before patching: ${security_before}"

      if [ "${DRY_RUN}" = "1" ]; then
        echo "--- apt-get -s upgrade ---"
        run_priv env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -s upgrade
        echo "--- apt-get -s full-upgrade ---"
        run_priv env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -s full-upgrade
      else
        run_priv env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get upgrade -y
        run_priv env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get full-upgrade -y
        run_priv apt-get autoremove -y
        run_priv apt-get autoclean -y
      fi

      after_count="$(apt list --upgradable 2>/dev/null | sed '1d' | wc -l | tr -d ' ')"
      security_after="$(count_apt_security_updates)"
      echo "Pending package updates after patching: ${after_count}"
      echo "Security updates after patching: ${security_after}"
      PENDING_PACKAGE_UPDATES_AFTER="${after_count}"
      VULN_PATCH_COUNT_SUPPORTED=1
      if [ "${DRY_RUN}" = "1" ]; then
        VULN_PATCHES_APPLIED=0
      else
        VULN_PATCHES_APPLIED=$((security_before - security_after))
        if [ "${VULN_PATCHES_APPLIED}" -lt 0 ]; then
          VULN_PATCHES_APPLIED=0
        fi
      fi
      ;;
    dnf)
      security_before="$(count_dnf_security_advisories "dnf")"
      if [ "${DRY_RUN}" = "1" ]; then
        run_priv dnf check-update --refresh || true
      else
        run_priv dnf upgrade --refresh -y
        run_priv dnf autoremove -y || true
      fi
      security_after="$(count_dnf_security_advisories "dnf")"
      echo "Security advisories before patching: ${security_before}"
      echo "Security advisories after patching: ${security_after}"
      if [ "${security_before}" -ge 0 ] && [ "${security_after}" -ge 0 ]; then
        VULN_PATCH_COUNT_SUPPORTED=1
        if [ "${DRY_RUN}" = "1" ]; then
          VULN_PATCHES_APPLIED=0
        else
          VULN_PATCHES_APPLIED=$((security_before - security_after))
          if [ "${VULN_PATCHES_APPLIED}" -lt 0 ]; then
            VULN_PATCHES_APPLIED=0
          fi
        fi
      fi
      ;;
    yum)
      security_before="$(count_dnf_security_advisories "yum")"
      if [ "${DRY_RUN}" = "1" ]; then
        run_priv yum check-update || true
      else
        run_priv yum update -y
        run_priv yum autoremove -y || true
      fi
      security_after="$(count_dnf_security_advisories "yum")"
      echo "Security advisories before patching: ${security_before}"
      echo "Security advisories after patching: ${security_after}"
      if [ "${security_before}" -ge 0 ] && [ "${security_after}" -ge 0 ]; then
        VULN_PATCH_COUNT_SUPPORTED=1
        if [ "${DRY_RUN}" = "1" ]; then
          VULN_PATCHES_APPLIED=0
        else
          VULN_PATCHES_APPLIED=$((security_before - security_after))
          if [ "${VULN_PATCHES_APPLIED}" -lt 0 ]; then
            VULN_PATCHES_APPLIED=0
          fi
        fi
      fi
      ;;
    zypper)
      if [ "${DRY_RUN}" = "1" ]; then
        run_priv zypper --non-interactive list-updates
      else
        run_priv zypper --non-interactive refresh
        run_priv zypper --non-interactive update
      fi
      ;;
  esac
}

refresh_docker() {
  print_section "Docker Refresh"

  if [ "${SKIP_DOCKER}" = "1" ]; then
    echo "Skipping Docker checks by request."
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not installed; skipping."
    return
  fi

  if ! run_priv docker info >/dev/null 2>&1; then
    echo "Docker daemon not reachable; skipping."
    return
  fi

  mapfile -t images < <(run_priv docker ps -a --format '{{.Image}}' | sed '/^$/d' | sort -u)
  if [ "${#images[@]}" -eq 0 ]; then
    echo "No Docker containers found."
    return
  fi

  declare -A UPDATED_IMAGE=()
  updated_images_count=0

  echo "Images in use: ${#images[@]}"
  for image in "${images[@]}"; do
    before_id="$(run_priv docker image inspect "${image}" --format '{{.Id}}' 2>/dev/null || true)"

    if [ "${DRY_RUN}" = "1" ]; then
      echo "Would pull: ${image}"
      continue
    fi

    set +e
    pull_out="$(run_priv docker pull "${image}" 2>&1)"
    pull_rc=$?
    set -e

    if [ "${pull_rc}" -ne 0 ]; then
      echo "Failed to pull ${image}: $(printf "%s\n" "${pull_out}" | tail -n1)"
      continue
    fi

    after_id="$(run_priv docker image inspect "${image}" --format '{{.Id}}' 2>/dev/null || true)"
    if [ -n "${before_id}" ] && [ -n "${after_id}" ] && [ "${before_id}" != "${after_id}" ]; then
      UPDATED_IMAGE["${image}"]=1
      updated_images_count=$((updated_images_count + 1))
      echo "Updated image: ${image}"
    else
      echo "Already current: ${image}"
    fi
  done

  if [ "${DRY_RUN}" = "1" ]; then
    return
  fi

  if [ "${updated_images_count}" -eq 0 ]; then
    echo "No new Docker images pulled."
    return
  fi

  declare -A compose_projects=()
  declare -a manual_recreate=()
  mapfile -t container_rows < <(run_priv docker ps -a --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}')
  for row in "${container_rows[@]}"; do
    IFS='|' read -r cname cimage cproject <<<"${row}"
    if [ "${UPDATED_IMAGE[${cimage}]:-0}" -eq 1 ]; then
      if [ -n "${cproject}" ]; then
        compose_projects["${cproject}"]=1
      else
        manual_recreate+=("${cname}")
      fi
    fi
  done

  for project in "${!compose_projects[@]}"; do
    info_row="$(run_priv docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' | head -n1)"
    IFS='|' read -r workdir config_files <<<"${info_row}"

    if [ -z "${workdir}" ]; then
      echo "Could not determine working directory for compose project '${project}', skipping."
      continue
    fi

    echo "Redeploying compose project '${project}' from ${workdir}"
    run_priv bash -lc '
      set -euo pipefail
      project_dir="$1"
      config_files_csv="$2"
      cd "$project_dir"

      IFS="," read -r -a cfgs <<<"$config_files_csv"
      args=()
      for cfg in "${cfgs[@]}"; do
        [ -n "$cfg" ] && args+=(-f "$cfg")
      done

      docker compose "${args[@]}" pull
      docker compose "${args[@]}" up -d --remove-orphans
    ' _ "${workdir}" "${config_files:-}"
  done

  if [ "${#manual_recreate[@]}" -gt 0 ]; then
    echo "Containers with updated images but not managed by compose:"
    for cname in "${manual_recreate[@]}"; do
      echo "  - ${cname}"
    done
    echo "Recreate these manually to run the new image."
  fi
}

apply_optional_hardening() {
  print_section "Optional Hardening"

  if [ "${ENABLE_UFW}" = "1" ]; then
    if ! command -v ufw >/dev/null 2>&1; then
      if [ "${PACKAGE_MANAGER}" = "apt" ]; then
        if [ "${DRY_RUN}" = "1" ]; then
          echo "Would install ufw."
        else
          run_priv apt-get install -y ufw
        fi
      else
        echo "UFW requested but this distro is not apt-based; skipping install."
      fi
    fi

    if command -v ufw >/dev/null 2>&1; then
      mapfile -t ssh_ports < <(run_priv sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -u)
      [ "${#ssh_ports[@]}" -eq 0 ] && ssh_ports=(22)

      if [ "${DRY_RUN}" = "1" ]; then
        echo "Would configure ufw defaults and allow SSH port(s): ${ssh_ports[*]}"
      else
        run_priv ufw default deny incoming
        run_priv ufw default allow outgoing
        for p in "${ssh_ports[@]}"; do
          run_priv ufw allow "${p}/tcp"
        done
        run_priv ufw --force enable
      fi
    fi
  else
    echo "UFW step skipped."
  fi

  if [ "${INSTALL_FAIL2BAN}" = "1" ]; then
    if [ "${PACKAGE_MANAGER}" = "apt" ]; then
      if [ "${DRY_RUN}" = "1" ]; then
        echo "Would install and enable fail2ban."
      else
        run_priv apt-get install -y fail2ban
        run_priv systemctl enable --now fail2ban
      fi
    elif [ "${PACKAGE_MANAGER}" = "dnf" ] || [ "${PACKAGE_MANAGER}" = "yum" ]; then
      if [ "${DRY_RUN}" = "1" ]; then
        echo "Would install and enable fail2ban."
      else
        run_priv "${PACKAGE_MANAGER}" install -y fail2ban
        run_priv systemctl enable --now fail2ban
      fi
    else
      echo "fail2ban install not implemented for package manager '${PACKAGE_MANAGER}'."
    fi
  else
    echo "fail2ban step skipped."
  fi
}

write_update_metrics() {
  print_section "Write Metrics"

  RUN_TS_EPOCH="$(date -u +%s)"
  RUN_TS_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=1
  else
    REBOOT_REQUIRED=0
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    echo "Dry-run: would write metrics files."
    echo "  - ${PROM_FILE}"
    echo "  - ${JSON_FILE}"
    return
  fi

  run_priv install -d -m 0755 "${METRICS_DIR}"
  run_priv install -d -m 0755 "$(dirname "${PROM_FILE}")"
  run_priv install -d -m 0755 "$(dirname "${JSON_FILE}")"

  prom_tmp="$(mktemp)"
  json_tmp="$(mktemp)"
  reboot_required_bool="false"
  if [ "${REBOOT_REQUIRED}" -eq 1 ]; then
    reboot_required_bool="true"
  fi

  cat > "${prom_tmp}" <<EOF
# HELP security_updates_last_run_timestamp_seconds Unix timestamp when update script completed.
# TYPE security_updates_last_run_timestamp_seconds gauge
security_updates_last_run_timestamp_seconds ${RUN_TS_EPOCH}
# HELP security_updates_vulnerability_patches_applied Number of vulnerability/security patches applied in this run.
# TYPE security_updates_vulnerability_patches_applied gauge
security_updates_vulnerability_patches_applied ${VULN_PATCHES_APPLIED}
# HELP security_updates_vulnerability_patch_count_supported Whether vulnerability patch counting is supported on this host/package manager.
# TYPE security_updates_vulnerability_patch_count_supported gauge
security_updates_vulnerability_patch_count_supported ${VULN_PATCH_COUNT_SUPPORTED}
# HELP security_updates_reboot_required Whether host reboot is required after patching (1=yes, 0=no).
# TYPE security_updates_reboot_required gauge
security_updates_reboot_required ${REBOOT_REQUIRED}
# HELP security_updates_pending_package_updates_after Pending package updates after this run (-1 if unknown).
# TYPE security_updates_pending_package_updates_after gauge
security_updates_pending_package_updates_after ${PENDING_PACKAGE_UPDATES_AFTER}
# HELP security_updates_last_run_dry_run Whether the last run was dry-run (1=yes, 0=no).
# TYPE security_updates_last_run_dry_run gauge
security_updates_last_run_dry_run ${DRY_RUN}
EOF

  cat > "${json_tmp}" <<EOF
{
  "host": "${HOST_NAME}",
  "last_run_utc": "${RUN_TS_ISO}",
  "last_run_epoch_seconds": ${RUN_TS_EPOCH},
  "dry_run": false,
  "package_manager": "${PACKAGE_MANAGER}",
  "vulnerability_patches_applied": ${VULN_PATCHES_APPLIED},
  "vulnerability_patch_count_supported": ${VULN_PATCH_COUNT_SUPPORTED},
  "pending_package_updates_after": ${PENDING_PACKAGE_UPDATES_AFTER},
  "reboot_required": ${reboot_required_bool}
}
EOF

  run_priv cp "${prom_tmp}" "${PROM_FILE}"
  run_priv cp "${json_tmp}" "${JSON_FILE}"
  run_priv chmod 0644 "${PROM_FILE}" "${JSON_FILE}"

  rm -f "${prom_tmp}" "${json_tmp}"

  echo "Metrics written:"
  echo "  - ${PROM_FILE}"
  echo "  - ${JSON_FILE}"

  if [ -d /var/lib/node_exporter/textfile_collector ]; then
    node_exporter_prom="/var/lib/node_exporter/textfile_collector/security_updates.prom"
    run_priv cp "${PROM_FILE}" "${node_exporter_prom}"
    run_priv chmod 0644 "${node_exporter_prom}"
    echo "Mirrored Prometheus metrics for node_exporter textfile collector:"
    echo "  - ${node_exporter_prom}"
  else
    echo "Node exporter textfile collector directory not found at /var/lib/node_exporter/textfile_collector."
    echo "If needed, point your healthcheck API/collector to: ${PROM_FILE}"
  fi
}

apply_os_updates
refresh_docker
apply_optional_hardening
write_update_metrics

print_section "Post-Update Status"
if [ "${REBOOT_REQUIRED}" -eq 1 ]; then
  echo "Reboot required: yes"
  if [ "${AUTO_REBOOT}" = "1" ] && [ "${DRY_RUN}" != "1" ]; then
    echo "Rebooting now..."
    run_priv reboot
  else
    echo "Run manually when ready: sudo reboot"
  fi
else
  echo "Reboot required: no"
fi
REMOTE_SCRIPT

echo
echo "==> Update run complete for ${TARGET_HOST}"
