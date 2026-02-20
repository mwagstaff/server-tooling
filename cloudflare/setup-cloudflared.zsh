#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_NAME="${0:t}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} HOST [install|verify|login]

Examples:
  ${SCRIPT_NAME} ocl
  ${SCRIPT_NAME} ocl install
  ${SCRIPT_NAME} ocl verify
  ${SCRIPT_NAME} ocl login

Behavior:
  If no step is provided, the script runs: install + verify + login.
EOF
}

run_remote_install() {
  log "Installing cloudflared on ${HOST}"
  ssh "${SSH_OPTS[@]}" "${HOST}" "bash -s" <<'EOF'
set -euo pipefail

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

detect_platform() {
  local os_name
  os_name="$(uname -s)"

  case "${os_name}" in
    Darwin)
      echo "macos"
      ;;
    Linux)
      if [[ -f /etc/os-release ]]; then
        local distro_id distro_like
        distro_id="$(. /etc/os-release && echo "${ID:-}")"
        distro_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
        if [[ "${distro_id}" == "ubuntu" || "${distro_id}" == "debian" || "${distro_like}" == *"ubuntu"* || "${distro_like}" == *"debian"* ]]; then
          echo "ubuntu"
        else
          echo "linux-unsupported"
        fi
      else
        echo "linux-unsupported"
      fi
      ;;
    *)
      echo "unsupported"
      ;;
  esac
}

install_on_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found on remote host."
  fi

  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared is already installed."
    cloudflared --version
    return
  fi

  log "Installing cloudflared with Homebrew..."
  brew install cloudflared
}

install_on_ubuntu() {
  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required for Ubuntu/Debian installation."
  fi

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")"
  if [[ -z "${codename}" ]]; then
    die "Could not determine Ubuntu/Debian codename from /etc/os-release."
  fi

  log "Installing prerequisites..."
  sudo apt-get update -y
  sudo apt-get install -y curl gnupg

  log "Configuring Cloudflare apt repository..."
  sudo install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${codename} main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

  log "Installing cloudflared with apt..."
  sudo apt-get update -y
  sudo apt-get install -y cloudflared
}

platform="$(detect_platform)"
case "${platform}" in
  macos)
    install_on_macos
    ;;
  ubuntu)
    install_on_ubuntu
    ;;
  linux-unsupported)
    die "Linux distro is not supported by this script. Supported: Ubuntu/Debian."
    ;;
  *)
    die "Unsupported OS. Supported: macOS, Ubuntu, Debian."
    ;;
esac
EOF
}

run_remote_verify() {
  log "Verifying cloudflared on ${HOST}"
  ssh "${SSH_OPTS[@]}" "${HOST}" "bash -s" <<'EOF'
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ERROR: cloudflared is not installed or not on PATH." >&2
  exit 1
fi

echo "cloudflared binary: $(command -v cloudflared)"
cloudflared --version
EOF
}

run_remote_login() {
  log "Running Cloudflare tunnel login on ${HOST}"
  ssh -tt "${SSH_OPTS[@]}" "${HOST}" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH'; command -v cloudflared >/dev/null 2>&1 || { echo 'ERROR: cloudflared is not installed or not on PATH.' >&2; exit 1; }; cloudflared tunnel login"
}

if [[ $# -eq 0 ]]; then
  usage
  die "HOST is required."
fi

if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 2 ]]; then
  usage
  die "Too many arguments."
fi

HOST="${1}"
ACTION="${2:-default}"

case "${ACTION}" in
  install)
    run_remote_install
    ;;
  verify)
    run_remote_verify
    ;;
  login)
    run_remote_login
    ;;
  default|all)
    run_remote_install
    run_remote_verify
    run_remote_login
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "Unknown action: ${ACTION}"
    ;;
esac
