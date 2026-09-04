#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh --artifact-root DIR [OPTIONS]

Options:
  --artifact-root DIR           Directory containing mongodb artifacts.
  --mongosh-version VERSION     Install this exact mongosh version.
  --install-database-tools BOOL Install MongoDB Database Tools (default: false).
  --database-tools-version VER  Install this exact Database Tools version.
  -h, --help                    Show help.
USAGE
}

ARTIFACT_ROOT="/opt/toolchain-artifacts/mongodb"
MONGOSH_VERSION=""
INSTALL_DATABASE_TOOLS="false"
DATABASE_TOOLS_VERSION=""

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --mongosh-version)
      MONGOSH_VERSION="$2"
      shift 2
      ;;
    --install-database-tools)
      INSTALL_DATABASE_TOOLS="$2"
      shift 2
      ;;
    --database-tools-version)
      DATABASE_TOOLS_VERSION="$2"
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

if [[ "${INSTALL_DATABASE_TOOLS}" != "true" && "${INSTALL_DATABASE_TOOLS}" != "false" ]]; then
  echo "ERROR: --install-database-tools must be true or false." >&2
  exit 1
fi

if [[ ! -d "${ARTIFACT_ROOT}" ]]; then
  echo "ERROR: artifact root not found: ${ARTIFACT_ROOT}" >&2
  exit 1
fi

find_single_artifact() {
  local tool="$1"
  local version="$2"
  local pattern="$3"
  local search_root="${ARTIFACT_ROOT}/${tool}"
  local found

  if [[ -n "${version}" ]]; then
    search_root="${search_root}/${version#v}"
  fi

  found="$(find "${search_root}" -type f -name "${pattern}" | sort -V | tail -1 || true)"
  if [[ -z "${found}" ]]; then
    echo "ERROR: ${tool} artifact not found under ${search_root} with pattern ${pattern}" >&2
    exit 1
  fi

  printf '%s\n' "${found}"
}

mongosh_archive="$(find_single_artifact mongosh "${MONGOSH_VERSION}" 'mongosh-*-linux-*.tgz')"

rm -rf /opt/mongosh /opt/mongodb-database-tools
rm -f /usr/bin/mongosh
for binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
  rm -f "/usr/bin/${binary}"
done
mkdir -p /opt/mongosh

tar -xzf "${mongosh_archive}" -C /opt/mongosh --strip-components=1 --no-same-owner
ln -sf /opt/mongosh/bin/mongosh /usr/bin/mongosh

if [[ "${INSTALL_DATABASE_TOOLS}" == "true" ]]; then
  database_tools_archive="$(find_single_artifact database-tools "${DATABASE_TOOLS_VERSION}" 'mongodb-database-tools-ubuntu2204-*.tgz')"
  mkdir -p /opt/mongodb-database-tools
  tar -xzf "${database_tools_archive}" -C /opt/mongodb-database-tools --strip-components=1 --no-same-owner

  for binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
    if [[ ! -x "/opt/mongodb-database-tools/bin/${binary}" ]]; then
      echo "ERROR: MongoDB Database Tools binary missing: ${binary}" >&2
      exit 1
    fi
    ln -sf "/opt/mongodb-database-tools/bin/${binary}" "/usr/bin/${binary}"
  done
fi

mongosh --version
if [[ "${INSTALL_DATABASE_TOOLS}" == "true" ]]; then
  mongodump --version
  mongorestore --version
  mongoimport --version
  mongoexport --version
  bsondump --version
  mongostat --version
  mongotop --version
  mongofiles --version
fi

echo "MongoDB tool install complete."
