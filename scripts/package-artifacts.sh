#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  package-artifacts.sh [options]

Options:
  --image IMAGE          Docker image to pull and save. Defaults to BASE_IMAGE.
  --artifact-root DIR   Artifact directory to package. Defaults to artifacts.
  --output FILE         Output tar.gz path. Defaults to artifacts-<image-name>-<version>.tar.gz.
  -h, --help            Show help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars BASE_IMAGE BASE_IMAGE_NAME BASE_IMAGE_VERSION

IMAGE_REF="${BASE_IMAGE}"
ARTIFACT_ROOT="${REPO_ROOT}/artifacts"
OUTPUT_PATH="${REPO_ROOT}/artifacts-${BASE_IMAGE_NAME}-${BASE_IMAGE_VERSION}.tar.gz"

while (($# > 0)); do
  case "$1" in
    --image)
      if (($# < 2)); then
        echo "ERROR: --image requires a value." >&2
        usage
        exit 1
      fi
      IMAGE_REF="$2"
      shift 2
      ;;
    --artifact-root)
      if (($# < 2)); then
        echo "ERROR: --artifact-root requires a value." >&2
        usage
        exit 1
      fi
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --output)
      if (($# < 2)); then
        echo "ERROR: --output requires a value." >&2
        usage
        exit 1
      fi
      OUTPUT_PATH="$2"
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

if [[ "${OUTPUT_PATH}" != /* ]]; then
  OUTPUT_PATH="${REPO_ROOT}/${OUTPUT_PATH}"
fi

safe_image_name="${IMAGE_REF//\//_}"
safe_image_name="${safe_image_name//:/_}"
IMAGE_ARTIFACT_DIR="${ARTIFACT_ROOT}/docker-images"
IMAGE_TAR="${IMAGE_ARTIFACT_DIR}/${safe_image_name}.tar"

if [[ "${OUTPUT_PATH}" == "${ARTIFACT_ROOT}"/* ]]; then
  echo "ERROR: output archive must not be inside the artifact root, or it would include itself:" >&2
  echo "  ${OUTPUT_PATH}" >&2
  exit 1
fi

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Preparing Docker image artifact:"
echo "  image:    ${IMAGE_REF}"
echo "  artifact: ${IMAGE_TAR}"

if ! docker pull "${IMAGE_REF}"; then
  echo "WARN: could not pull ${IMAGE_REF}; checking for a local image tag." >&2
  if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
    echo "ERROR: image is not available locally after pull failure:" >&2
    echo "  ${IMAGE_REF}" >&2
    exit 1
  fi
fi

mkdir -p "${IMAGE_ARTIFACT_DIR}"
docker save --output "${IMAGE_TAR}" "${IMAGE_REF}"
sha256sum "${IMAGE_TAR}" > "${IMAGE_TAR}.sha256"

echo "Saved Docker image artifact:"
echo "  ${IMAGE_TAR}"
echo "  ${IMAGE_TAR}.sha256"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
tar -C "$(dirname "${ARTIFACT_ROOT}")" -czf "${OUTPUT_PATH}" "$(basename "${ARTIFACT_ROOT}")"
sha256sum "${OUTPUT_PATH}" > "${OUTPUT_PATH}.sha256"

echo "Packaged artifact directory:"
echo "  ${OUTPUT_PATH}"
echo "  ${OUTPUT_PATH}.sha256"
