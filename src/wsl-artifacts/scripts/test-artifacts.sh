#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  test-artifacts.sh [options]

Options:
  --artifact-root DIR   Artifact root. Defaults to WSL_ARTIFACT_ROOT.
  -h, --help            Show help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"

WSL_CONFIG_FILE="${WSL_ENV_FILE:-${REPO_ROOT}/config/wsl-artifacts.env}"
if [[ "${WSL_CONFIG_FILE}" != /* ]]; then
  WSL_CONFIG_FILE="${REPO_ROOT}/${WSL_CONFIG_FILE}"
fi

if [[ -f "${WSL_CONFIG_FILE}" ]]; then
  # shellcheck source=config/wsl-artifacts.env
  source "${WSL_CONFIG_FILE}"
fi

ARTIFACT_ROOT="${WSL_ARTIFACT_ROOT:-artifacts/wsl}"

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      if (($# < 2)); then
        echo "ERROR: --artifact-root requires a value." >&2
        usage
        exit 1
      fi
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

if [[ "${ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${ARTIFACT_ROOT}"
fi

MANIFEST_PATH="${ARTIFACT_ROOT}/manifest.json"

for cmd in jq sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "ERROR: WSL artifact manifest not found:" >&2
  echo "  ${MANIFEST_PATH}" >&2
  echo "Run ./src/wsl-artifacts/scripts/prefetch.sh first." >&2
  exit 1
fi

jq empty "${MANIFEST_PATH}"

server_count="$(jq '[.artifacts[] | select(.kind == "vscode-server")] | length' "${MANIFEST_PATH}")"
extension_count="$(jq '[.artifacts[] | select(.kind == "vscode-extension")] | length' "${MANIFEST_PATH}")"
docker_image_count="$(jq '[.artifacts[] | select(.kind == "docker-image")] | length' "${MANIFEST_PATH}")"

if [[ "${server_count}" -lt 1 ]]; then
  echo "ERROR: manifest does not contain a VS Code Server artifact." >&2
  exit 1
fi

if [[ "${extension_count}" -lt 1 ]]; then
  echo "ERROR: manifest does not contain a VS Code extension artifact." >&2
  exit 1
fi

prefetch_bootstrap_image="${WSL_PREFETCH_DEVCONTAINERS_BOOTSTRAP_IMAGE:-true}"
if [[ ! "${prefetch_bootstrap_image,,}" =~ ^(0|false|no|off)$ ]] && [[ "${docker_image_count}" -lt 1 ]]; then
  echo "ERROR: manifest does not contain the Dev Containers bootstrap container image artifact." >&2
  exit 1
fi

while IFS=$'\t' read -r relative_path expected_sha256; do
  artifact_path="${ARTIFACT_ROOT}/${relative_path}"
  if [[ ! -f "${artifact_path}" ]]; then
    echo "ERROR: manifest artifact is missing:" >&2
    echo "  ${artifact_path}" >&2
    exit 1
  fi

  echo "${expected_sha256}  ${artifact_path}" | sha256sum --check --strict
done < <(jq -r '.artifacts[] | [.path, .sha256] | @tsv' "${MANIFEST_PATH}")

echo "WSL artifact test completed successfully:"
echo "  ${MANIFEST_PATH}"
