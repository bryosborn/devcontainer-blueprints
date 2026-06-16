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
  MONGOSH_VERSION \
  MONGODB_DATABASE_TOOLS_VERSION

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")/mongodb"

case "${TOOLCHAIN_ARCH}" in
  amd64)
    MONGOSH_ARCH="x64"
    DATABASE_TOOLS_ARCH="x86_64"
    ;;
  arm64)
    MONGOSH_ARCH="arm64"
    DATABASE_TOOLS_ARCH="arm64"
    ;;
  *)
    echo "ERROR: unsupported TOOLCHAIN_ARCH for mongodb: ${TOOLCHAIN_ARCH}" >&2
    exit 1
    ;;
esac

fetch_tool() {
  local tool="$1"
  local version="$2"
  local url="$3"
  local file_name="$4"
  local expected_hash="$5"
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

  verify_optional_hash "sha256" "${expected_hash}" "${artifact}"
  hash_value="$(actual_hash "sha256" "${artifact}")"

  echo "${hash_value}  ${file_name}" > "${dest_dir}/CHECKSUMS"
  write_tool_metadata \
    "${dest_dir}/metadata.json" \
    "${tool}" \
    "${version}" \
    "${TOOLCHAIN_PLATFORM}" \
    "${url}" \
    "${file_name}" \
    "sha256" \
    "${hash_value}"
}

fetch_tool \
  "mongosh" \
  "${MONGOSH_VERSION}" \
  "https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-linux-${MONGOSH_ARCH}.tgz" \
  "mongosh-${MONGOSH_VERSION}-linux-${MONGOSH_ARCH}.tgz" \
  "${MONGOSH_SHA256:-}"

fetch_tool \
  "database-tools" \
  "${MONGODB_DATABASE_TOOLS_VERSION}" \
  "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2204-${DATABASE_TOOLS_ARCH}-${MONGODB_DATABASE_TOOLS_VERSION}.tgz" \
  "mongodb-database-tools-ubuntu2204-${DATABASE_TOOLS_ARCH}-${MONGODB_DATABASE_TOOLS_VERSION}.tgz" \
  "${MONGODB_DATABASE_TOOLS_SHA256:-}"

echo "MongoDB tool artifacts complete:"
echo "  ${ARTIFACT_ROOT}"
