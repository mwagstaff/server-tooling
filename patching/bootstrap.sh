#!/bin/bash
# Run on your laptop/controller; the installer connects to the named Ubuntu host over SSH.
set -euo pipefail
main() (
  local stage ref
  ref="${MAINTENANCE_REF:-main}"
  [[ "$ref" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo 'Invalid MAINTENANCE_REF' >&2; return 1; }
  stage="$(mktemp -d)"
  trap 'rm -rf -- "$stage"' EXIT
  curl --fail --silent --show-error --location "https://github.com/mwagstaff/server-tooling/archive/${ref}.tar.gz" -o "$stage/source.tar.gz"
  mkdir "$stage/source"
  tar -xzf "$stage/source.tar.gz" -C "$stage/source" --strip-components=1
  python3 "$stage/source/patching/install-maintenance.py" "$@"
)
main "$@"
