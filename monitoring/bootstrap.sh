#!/bin/bash
# Download completely before execution; set MONITORING_REF to a reviewed commit.
set -euo pipefail
main() (
  local stage ref
  ref="${MONITORING_REF:-main}"
  [[ "$ref" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo 'Invalid MONITORING_REF' >&2; return 1; }
  stage="$(mktemp -d)"
  trap 'rm -rf -- "$stage"' EXIT
  curl --fail --silent --show-error --location "https://github.com/mwagstaff/server-tooling/archive/${ref}.tar.gz" -o "$stage/source.tar.gz"
  mkdir "$stage/source"
  tar -xzf "$stage/source.tar.gz" -C "$stage/source" --strip-components=1
  bash "$stage/source/monitoring/install.sh" "$@"
)
main "$@"
