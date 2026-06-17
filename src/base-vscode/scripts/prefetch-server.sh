#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  prefetch-server.sh [options]

Options:
  --version VERSION             VS Code product version, e.g. 1.124.2 or latest.
  --commit COMMIT              Exact VS Code commit SHA. If set, version resolution is skipped.
  --quality QUALITY            VS Code quality. Initial supported value: stable.
  --client-platform PLATFORM   Metadata platform, e.g. linux-x64 or linux-arm64.
  --server-platform PLATFORM   Server platform, e.g. server-linux-x64 or server-linux-arm64.
  --artifact-root DIR          Artifact root. Default comes from config/docker.env.
  -h, --help                   Show help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"

VSCODE_VERSION="${BASE_VSCODE_VERSION:-latest}"
VSCODE_COMMIT="${BASE_VSCODE_COMMIT:-}"
VSCODE_QUALITY="${BASE_VSCODE_QUALITY:-stable}"
VSCODE_CLIENT_PLATFORM="${BASE_VSCODE_CLIENT_PLATFORM:-linux-x64}"
VSCODE_SERVER_PLATFORM="${BASE_VSCODE_SERVER_PLATFORM:-server-linux-x64}"
VSCODE_SERVER_ARTIFACT_ROOT="${BASE_VSCODE_ARTIFACT_ROOT:-artifacts/vscode-server}"

while (($# > 0)); do
  case "$1" in
    --version)
      VSCODE_VERSION="$2"
      VSCODE_COMMIT=""
      shift 2
      ;;
    --commit)
      VSCODE_COMMIT="$2"
      VSCODE_VERSION=""
      shift 2
      ;;
    --quality)
      VSCODE_QUALITY="$2"
      shift 2
      ;;
    --client-platform)
      VSCODE_CLIENT_PLATFORM="$2"
      shift 2
      ;;
    --server-platform)
      VSCODE_SERVER_PLATFORM="$2"
      shift 2
      ;;
    --artifact-root)
      VSCODE_SERVER_ARTIFACT_ROOT="$2"
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

if [[ "${VSCODE_QUALITY}" != "stable" ]]; then
  echo "ERROR: initial implementation supports only --quality stable." >&2
  exit 1
fi

case "${VSCODE_SERVER_PLATFORM}" in
  server-linux-x64|server-linux-arm64) ;;
  *)
    echo "ERROR: initial implementation supports only server-linux-x64 and server-linux-arm64." >&2
    exit 1
    ;;
esac

for cmd in curl jq sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ "${VSCODE_SERVER_ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT_ABS="${REPO_ROOT}/${VSCODE_SERVER_ARTIFACT_ROOT}"
else
  ARTIFACT_ROOT_ABS="${VSCODE_SERVER_ARTIFACT_ROOT}"
fi

json_field_or_empty() {
  local json="$1"
  local field="$2"
  jq -r "${field} // empty" <<<"${json}"
}

resolve_commit_from_version() {
  local version="$1"
  local quality="$2"
  local client_platform="$3"
  local metadata_url

  if [[ "${version}" == "latest" ]]; then
    metadata_url="https://update.code.visualstudio.com/api/update/${client_platform}/${quality}/latest"
  else
    metadata_url="https://update.code.visualstudio.com/api/versions/${version}/${client_platform}/${quality}"
  fi

  echo "Resolving VS Code metadata:" >&2
  echo "  ${metadata_url}" >&2

  curl --fail --silent --show-error --location "${metadata_url}"
}

download_with_retries() {
  local url="$1"
  local output="$2"

  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --show-error \
    --output "${output}" \
    "${url}"
}

PRODUCT_VERSION="${VSCODE_VERSION}"
RESOLVED_METADATA=""

if [[ -z "${VSCODE_COMMIT}" ]]; then
  RESOLVED_METADATA="$(resolve_commit_from_version "${VSCODE_VERSION}" "${VSCODE_QUALITY}" "${VSCODE_CLIENT_PLATFORM}")"
  VSCODE_COMMIT="$(json_field_or_empty "${RESOLVED_METADATA}" '.version')"
  PRODUCT_VERSION="$(json_field_or_empty "${RESOLVED_METADATA}" '.productVersion')"
  if [[ -z "${PRODUCT_VERSION}" ]]; then
    PRODUCT_VERSION="$(json_field_or_empty "${RESOLVED_METADATA}" '.name')"
  fi
  if [[ -z "${PRODUCT_VERSION}" ]]; then
    PRODUCT_VERSION="${VSCODE_VERSION}"
  fi
else
  echo "Using explicit VS Code commit:"
  echo "  ${VSCODE_COMMIT}"
fi

if ! [[ "${VSCODE_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: commit does not look like a 40-character SHA: ${VSCODE_COMMIT}" >&2
  exit 1
fi

SERVER_METADATA_URL="https://update.code.visualstudio.com/api/versions/commit:${VSCODE_COMMIT}/${VSCODE_SERVER_PLATFORM}/${VSCODE_QUALITY}"

echo "Resolving VS Code Server metadata:"
echo "  ${SERVER_METADATA_URL}"

SERVER_METADATA=""
if SERVER_METADATA="$(curl --fail --silent --show-error --location "${SERVER_METADATA_URL}")"; then
  SERVER_URL="$(json_field_or_empty "${SERVER_METADATA}" '.url')"
  SERVER_SHA256="$(json_field_or_empty "${SERVER_METADATA}" '.sha256hash')"
else
  echo "WARNING: server metadata endpoint failed; falling back to constructed download URL." >&2
  SERVER_URL=""
  SERVER_SHA256=""
fi

if [[ -z "${SERVER_URL}" ]]; then
  SERVER_URL="https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/${VSCODE_SERVER_PLATFORM}/${VSCODE_QUALITY}"
fi

SERVER_SUFFIX="${VSCODE_SERVER_PLATFORM#server-}"
ARCHIVE_NAME="vscode-server-${SERVER_SUFFIX}.tar.gz"

DEST_DIR="${ARTIFACT_ROOT_ABS}/${VSCODE_QUALITY}/${VSCODE_COMMIT}/${VSCODE_SERVER_PLATFORM}"
ARCHIVE_PATH="${DEST_DIR}/${ARCHIVE_NAME}"
METADATA_PATH="${DEST_DIR}/metadata.json"
SHA_PATH="${DEST_DIR}/SHA256SUMS"
CURRENT_POINTER="${ARTIFACT_ROOT_ABS}/current-${VSCODE_QUALITY}-${VSCODE_SERVER_PLATFORM}.json"

mkdir -p "${DEST_DIR}"

NEEDS_DOWNLOAD=1

if [[ -f "${ARCHIVE_PATH}" ]]; then
  if [[ -n "${SERVER_SHA256}" ]]; then
    if echo "${SERVER_SHA256}  ${ARCHIVE_PATH}" | sha256sum --check --status; then
      NEEDS_DOWNLOAD=0
      echo "Archive already exists and SHA256 matches:"
      echo "  ${ARCHIVE_PATH}"
    fi
  else
    NEEDS_DOWNLOAD=0
    echo "Archive already exists; no upstream SHA256 available to verify:"
    echo "  ${ARCHIVE_PATH}"
  fi
fi

if [[ "${NEEDS_DOWNLOAD}" -eq 1 ]]; then
  TMP_PATH="${ARCHIVE_PATH}.tmp"
  rm -f "${TMP_PATH}"

  echo "Downloading VS Code Server:"
  echo "  ${SERVER_URL}"
  echo "to:"
  echo "  ${ARCHIVE_PATH}"

  download_with_retries "${SERVER_URL}" "${TMP_PATH}"

  if [[ -n "${SERVER_SHA256}" ]]; then
    echo "${SERVER_SHA256}  ${TMP_PATH}" | sha256sum --check
  fi

  mv "${TMP_PATH}" "${ARCHIVE_PATH}"
fi

ACTUAL_SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"

cat > "${SHA_PATH}" <<EOF
${ACTUAL_SHA256}  ${ARCHIVE_NAME}
EOF

jq -n \
  --arg productVersion "${PRODUCT_VERSION}" \
  --arg commit "${VSCODE_COMMIT}" \
  --arg quality "${VSCODE_QUALITY}" \
  --arg clientPlatform "${VSCODE_CLIENT_PLATFORM}" \
  --arg serverPlatform "${VSCODE_SERVER_PLATFORM}" \
  --arg url "${SERVER_URL}" \
  --arg archive "${ARCHIVE_PATH}" \
  --arg archiveName "${ARCHIVE_NAME}" \
  --arg sha256 "${ACTUAL_SHA256}" \
  --arg downloadedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    productVersion: $productVersion,
    commit: $commit,
    quality: $quality,
    clientPlatform: $clientPlatform,
    serverPlatform: $serverPlatform,
    url: $url,
    archive: $archive,
    archiveName: $archiveName,
    sha256: $sha256,
    downloadedAt: $downloadedAt
  }' > "${METADATA_PATH}"

cp "${METADATA_PATH}" "${CURRENT_POINTER}"

echo "Prefetch complete."
echo "  commit:   ${VSCODE_COMMIT}"
echo "  archive:  ${ARCHIVE_PATH}"
echo "  metadata: ${METADATA_PATH}"
echo "  current:  ${CURRENT_POINTER}"
