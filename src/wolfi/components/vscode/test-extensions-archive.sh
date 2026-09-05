#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 LOCKFILE ARCHIVE" >&2
  exit 2
fi
LOCKFILE="$(realpath "$1")"
ARCHIVE="$(realpath "$2")"
ARCHIVE_CHECKSUM="${ARCHIVE}.sha256"
ARTIFACT_ROOT="$(dirname "${ARCHIVE}")"

for file_path in "${LOCKFILE}" "${ARCHIVE}" "${ARCHIVE_CHECKSUM}"; do
  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: required VS Code extension artifact not found: ${file_path}" >&2
    exit 1
  fi
done

(
  cd "${ARTIFACT_ROOT}"
  sha256sum --check --strict "$(basename "${ARCHIVE_CHECKSUM}")"
)

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT
tar -xzf "${ARCHIVE}" -C "${STAGING_DIR}"

PAYLOAD_DIR="${STAGING_DIR}/vscode-extensions"
cmp "${LOCKFILE}" "${PAYLOAD_DIR}/vscode-extensions.lock.json"
(
  cd "${PAYLOAD_DIR}"
  sha256sum --check --strict SHA256SUMS
)

EXPECTED_SERVER_COUNT="$(jq '.containerInstallOrder | length' "${LOCKFILE}")"
EXPECTED_CLIENT_COUNT="$(jq '.hostOnlyExtensions | length' "${LOCKFILE}")"
ACTUAL_SERVER_COUNT="$(find "${PAYLOAD_DIR}/server" -type f -name '*.vsix' | wc -l | tr -d ' ')"
ACTUAL_CLIENT_COUNT="$(find "${PAYLOAD_DIR}/client" -type f -name '*.vsix' | wc -l | tr -d ' ')"

test "${ACTUAL_SERVER_COUNT}" = "${EXPECTED_SERVER_COUNT}"
test "${ACTUAL_CLIENT_COUNT}" = "${EXPECTED_CLIENT_COUNT}"

echo "VS Code extension archive test completed successfully:"
echo "  ${ARCHIVE}"
echo "  server extensions: ${ACTUAL_SERVER_COUNT}"
echo "  client extensions: ${ACTUAL_CLIENT_COUNT}"
