#!/bin/sh
set -eu

install_root="/usr/local/share/wolfi-dod"
source_script="$(dirname "$0")/docker-socket-proxy-entrypoint.sh"

if [ ! -f "${source_script}" ]; then
  echo "ERROR: Wolfi DOD socket proxy entrypoint is missing: ${source_script}" >&2
  exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
  echo "ERROR: socat must be installed by the Wolfi DOD base image." >&2
  exit 1
fi

install -d -o root -g root -m 0755 "${install_root}"
install -o root -g root -m 0755 \
  "${source_script}" \
  "${install_root}/docker-socket-proxy-entrypoint.sh"

echo "Installed the package-free Wolfi DOD runtime Feature."
