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
  JAVA_VERSION \
  MAVEN_VERSION

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")/java-maven"

case "${TOOLCHAIN_ARCH}" in
  amd64)
    JAVA_ARCH="x64"
    ;;
  arm64)
    JAVA_ARCH="aarch64"
    ;;
  *)
    echo "ERROR: unsupported TOOLCHAIN_ARCH for java-maven: ${TOOLCHAIN_ARCH}" >&2
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

java_major="${JAVA_VERSION%%.*}"
java_release_version="${JAVA_VERSION/+/%2B}"
java_file_version="${JAVA_VERSION/+/_}"
java_file="OpenJDK${java_major}U-jdk_${JAVA_ARCH}_linux_hotspot_${java_file_version}.tar.gz"

fetch_tool \
  "java" \
  "${JAVA_VERSION}" \
  "https://github.com/adoptium/temurin${java_major}-binaries/releases/download/jdk-${java_release_version}/${java_file}" \
  "${java_file}" \
  "sha256" \
  "${JAVA_SHA256:-}"

fetch_tool \
  "maven" \
  "${MAVEN_VERSION}" \
  "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
  "apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
  "sha512" \
  "${MAVEN_SHA512:-}"

echo "Java and Maven artifacts complete:"
echo "  ${ARTIFACT_ROOT}"
