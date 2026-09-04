#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"

EXT_ENV_FILE="${REPO_ROOT}/config/vscode-extensions.env"
if [[ ! -f "${EXT_ENV_FILE}" ]]; then
  echo "ERROR: VS Code extension config file not found: ${EXT_ENV_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${EXT_ENV_FILE}"

require_env_vars \
  VSCODE_EXTENSIONS_ARTIFACT_ROOT \
  VSCODE_EXTENSIONS_ARCHIVE_NAME

if [[ "${VSCODE_EXTENSIONS_ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${VSCODE_EXTENSIONS_ARTIFACT_ROOT}"
else
  ARTIFACT_ROOT="${VSCODE_EXTENSIONS_ARTIFACT_ROOT}"
fi

LOCKFILE="${ARTIFACT_ROOT}/vscode-extensions.lock.json"
ARCHIVE="${ARTIFACT_ROOT}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"
ARCHIVE_CHECKSUM="${ARCHIVE}.sha256"

for file_path in "${LOCKFILE}" "${ARCHIVE}" "${ARCHIVE_CHECKSUM}"; do
  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: required VS Code extension artifact not found: ${file_path}" >&2
    echo "Run ./src/base-vscode/scripts/prefetch-extensions.sh first." >&2
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
