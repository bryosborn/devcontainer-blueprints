#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh --artifact-root DIR

Options:
  --artifact-root DIR     Directory containing mongodb artifacts.
  -h, --help              Show help.
USAGE
}

ARTIFACT_ROOT="/opt/toolchain-artifacts/mongodb"

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

mongosh_archive="$(find_single_artifact mongosh 'mongosh-*-linux-*.tgz')"
database_tools_archive="$(find_single_artifact database-tools 'mongodb-database-tools-ubuntu2204-*.tgz')"

rm -rf /opt/mongosh /opt/mongodb-database-tools
mkdir -p /opt/mongosh /opt/mongodb-database-tools

tar -xzf "${mongosh_archive}" -C /opt/mongosh --strip-components=1 --no-same-owner
tar -xzf "${database_tools_archive}" -C /opt/mongodb-database-tools --strip-components=1 --no-same-owner

ln -sf /opt/mongosh/bin/mongosh /usr/bin/mongosh

for binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
  if [[ ! -x "/opt/mongodb-database-tools/bin/${binary}" ]]; then
    echo "ERROR: MongoDB Database Tools binary missing: ${binary}" >&2
    exit 1
  fi
  ln -sf "/opt/mongodb-database-tools/bin/${binary}" "/usr/bin/${binary}"
done

mongosh --version
mongodump --version
mongorestore --version
mongoimport --version
mongoexport --version
bsondump --version
mongostat --version
mongotop --version
mongofiles --version

echo "MongoDB tool install complete."
