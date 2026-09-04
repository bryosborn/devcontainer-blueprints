#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh --artifact-root DIR [--version VERSION]

Options:
  --artifact-root DIR     Directory containing node artifacts.
  --version VERSION       Install this exact Node version.
  -h, --help              Show help.
USAGE
}

ARTIFACT_ROOT="/opt/toolchain-artifacts/node"
NODE_VERSION=""

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --version)
      NODE_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -d "${ARTIFACT_ROOT}" ]]; then
  echo "ERROR: artifact root not found: ${ARTIFACT_ROOT}" >&2
  exit 1
fi

node_search_root="${ARTIFACT_ROOT}/node"
if [[ -n "${NODE_VERSION}" ]]; then
  node_search_root="${node_search_root}/${NODE_VERSION#v}"
fi

node_archive="$(find "${node_search_root}" -type f -name 'node-v*-linux-*.tar.gz' | sort -V | tail -1 || true)"
if [[ -z "${node_archive}" ]]; then
  echo "ERROR: node artifact not found under ${node_search_root}" >&2
  exit 1
fi

node_version=$(basename "$node_archive" | sed -E 's/^node-(v[^-]+)-linux-.*$/\1/')

rm -rf /opt/node
mkdir -p /opt/node
mkdir -p "/opt/downloads/node/${node_version}/"
cp "${node_archive}" "/opt/downloads/node/${node_version}/"
tar -xzf "${node_archive}" -C /opt/node --strip-components=1 --no-same-owner

for binary in node npm npx corepack; do
  if [[ -e "/opt/node/bin/${binary}" ]]; then
    ln -sf "/opt/node/bin/${binary}" "/usr/bin/${binary}"
  fi
done

node --version
npm --version
npx --version

echo "Node install complete."
