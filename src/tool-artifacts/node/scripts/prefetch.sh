#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars \
  TOOLCHAIN_PLATFORM \
  TOOLCHAIN_ARCH \
  TOOLCHAIN_ARTIFACT_ROOT \
  NODE_VERSION

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")/node"

case "${TOOLCHAIN_ARCH}" in
  amd64) NODE_ARCH="x64" ;;
  arm64) NODE_ARCH="arm64" ;;
  *)
    echo "ERROR: unsupported TOOLCHAIN_ARCH for node: ${TOOLCHAIN_ARCH}" >&2
    exit 1
    ;;
esac

node_version_no_v="${NODE_VERSION#v}"
node_version_with_v="v${node_version_no_v}"
file_name="node-${node_version_with_v}-linux-${NODE_ARCH}.tar.gz"
url="https://nodejs.org/dist/${node_version_with_v}/${file_name}"
dest_dir="${ARTIFACT_ROOT}/node/${node_version_no_v}/${TOOLCHAIN_PLATFORM}"
artifact="${dest_dir}/${file_name}"

mkdir -p "${dest_dir}"

if [[ ! -f "${artifact}" ]]; then
  echo "Downloading node ${node_version_no_v}:"
  echo "  ${url}"
  download_artifact "${url}" "${artifact}"
else
  echo "Using existing node artifact:"
  echo "  ${artifact}"
fi

verify_optional_hash "sha256" "${NODE_SHA256:-}" "${artifact}"
hash_value="$(actual_hash "sha256" "${artifact}")"

echo "${hash_value}  ${file_name}" > "${dest_dir}/CHECKSUMS"
write_tool_metadata \
  "${dest_dir}/metadata.json" \
  "node" \
  "${node_version_no_v}" \
  "${TOOLCHAIN_PLATFORM}" \
  "${url}" \
  "${file_name}" \
  "sha256" \
  "${hash_value}"

echo "Node artifacts complete:"
echo "  ${ARTIFACT_ROOT}"
