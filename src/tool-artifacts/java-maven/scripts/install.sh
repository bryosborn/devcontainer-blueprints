#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh --artifact-root DIR

Options:
  --artifact-root DIR     Directory containing java-maven artifacts.
  -h, --help              Show help.
USAGE
}

ARTIFACT_ROOT="/opt/toolchain-artifacts/java-maven"

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      ARTIFACT_ROOT="$2"
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

find_single_artifact() {
  local tool="$1"
  local pattern="$2"
  local found

  found="$(find "${ARTIFACT_ROOT}/${tool}" -type f -name "${pattern}" | sort | tail -1 || true)"
  if [[ -z "${found}" ]]; then
    echo "ERROR: ${tool} artifact not found with pattern ${pattern}" >&2
    exit 1
  fi

  printf '%s\n' "${found}"
}

install_archive_root() {
  local tool="$1"
  local archive="$2"
  local dest_dir="$3"

  rm -rf "${dest_dir}"
  mkdir -p "${dest_dir}"
  tar -xzf "${archive}" -C "${dest_dir}" --strip-components=1 --no-same-owner
}

java_archive="$(find_single_artifact java 'OpenJDK*U-jdk_*_linux_hotspot_*.tar.gz')"
maven_archive="$(find_single_artifact maven 'apache-maven-*-bin.tar.gz')"

install_archive_root "java" "${java_archive}" "/opt/java"
install_archive_root "maven" "${maven_archive}" "/opt/maven"

find /opt/java/bin -maxdepth 1 -type f -executable -exec ln -sf {} /usr/bin/ \;
ln -sf /opt/maven/bin/mvn /usr/bin/mvn
ln -sf /opt/maven/bin/mvnDebug /usr/bin/mvnDebug

java --version
javac --version
mvn --version

echo "Java and Maven install complete."
