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
  HELM_VERSION \
  KUBECTL_VERSION \
  ORAS_VERSION \
  YQ_VERSION

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")/cli-tools"

case "${TOOLCHAIN_ARCH}" in
  amd64) ARCHIVE_ARCH="amd64" ;;
  arm64) ARCHIVE_ARCH="arm64" ;;
  *)
    echo "ERROR: unsupported TOOLCHAIN_ARCH for cli-tools: ${TOOLCHAIN_ARCH}" >&2
    exit 1
    ;;
esac

fetch_tool() {
  local tool="$1"
  local version="$2"
  local url="$3"
  local file_name="$4"
  local hash_algorithm="$5"
  local expected_hash="$6"
  local dest_dir="${ARTIFACT_ROOT}/${tool}/${version}/${TOOLCHAIN_PLATFORM}"
  local artifact="${dest_dir}/${file_name}"
  local hash_value

  mkdir -p "${dest_dir}"

  if [[ ! -f "${artifact}" ]]; then
    echo "Downloading ${tool} ${version}:"
    echo "  ${url}"
    download_artifact "${url}" "${artifact}"
  else
    echo "Using existing ${tool} artifact:"
    echo "  ${artifact}"
  fi

  verify_optional_hash "${hash_algorithm}" "${expected_hash}" "${artifact}"
  hash_value="$(actual_hash "${hash_algorithm}" "${artifact}")"

  echo "${hash_value}  ${file_name}" > "${dest_dir}/CHECKSUMS"
  write_tool_metadata \
    "${dest_dir}/metadata.json" \
    "${tool}" \
    "${version}" \
    "${TOOLCHAIN_PLATFORM}" \
    "${url}" \
    "${file_name}" \
    "${hash_algorithm}" \
    "${hash_value}"
}

fetch_tool \
  "helm" \
  "${HELM_VERSION}" \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCHIVE_ARCH}.tar.gz" \
  "helm-v${HELM_VERSION}-linux-${ARCHIVE_ARCH}.tar.gz" \
  "sha256" \
  "${HELM_SHA256:-}"

fetch_tool \
  "kubectl" \
  "${KUBECTL_VERSION}" \
  "https://dl.k8s.io/v${KUBECTL_VERSION}/kubernetes-client-linux-${ARCHIVE_ARCH}.tar.gz" \
  "kubernetes-client-linux-${ARCHIVE_ARCH}.tar.gz" \
  "sha512" \
  "${KUBECTL_SHA512:-}"

fetch_tool \
  "oras" \
  "${ORAS_VERSION}" \
  "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ARCHIVE_ARCH}.tar.gz" \
  "oras_${ORAS_VERSION}_linux_${ARCHIVE_ARCH}.tar.gz" \
  "sha256" \
  "${ORAS_SHA256:-}"

fetch_tool \
  "yq" \
  "${YQ_VERSION}" \
  "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCHIVE_ARCH}.tar.gz" \
  "yq_linux_${ARCHIVE_ARCH}.tar.gz" \
  "sha256" \
  "${YQ_SHA256:-}"

echo "CLI tool artifacts complete:"
echo "  ${ARTIFACT_ROOT}"
