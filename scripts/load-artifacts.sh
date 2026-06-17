#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  load-artifacts.sh [options]

Options:
  --artifact-root DIR   Artifact directory to load from. Defaults to artifacts.
  --no-verify           Skip SHA256 verification before loading image tar files.
  -h, --help            Show help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ARTIFACT_ROOT="${REPO_ROOT}/artifacts"
VERIFY_HASHES=1

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
    --no-verify)
      VERIFY_HASHES=0
      shift
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

IMAGE_ARTIFACT_DIR="${ARTIFACT_ROOT}/docker-images"
MANIFEST_PATH="${ARTIFACT_ROOT}/manifest.json"

if [[ ! -d "${IMAGE_ARTIFACT_DIR}" ]]; then
  echo "ERROR: Docker image artifact directory not found:" >&2
  echo "  ${IMAGE_ARTIFACT_DIR}" >&2
  echo "Run ./scripts/package-artifacts.sh on the online machine first." >&2
  exit 1
fi

if [[ "${VERIFY_HASHES}" -eq 1 ]]; then
  shopt -s nullglob
  sha_files=("${IMAGE_ARTIFACT_DIR}"/*.tar.sha256)
  shopt -u nullglob

  if ((${#sha_files[@]} == 0)); then
    echo "ERROR: no Docker image SHA256 files found in:" >&2
    echo "  ${IMAGE_ARTIFACT_DIR}" >&2
    exit 1
  fi

  echo "Verifying Docker image artifact hashes:"
  for sha_file in "${sha_files[@]}"; do
    (
      cd "${IMAGE_ARTIFACT_DIR}"
      sha256sum --check --strict "$(basename "${sha_file}")"
    )
  done
fi

image_tars=()
image_refs=()

if [[ -f "${MANIFEST_PATH}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to read artifact manifest:" >&2
    echo "  ${MANIFEST_PATH}" >&2
    exit 1
  fi

  while IFS= read -r tar_path; do
    image_tars+=("${ARTIFACT_ROOT}/${tar_path}")
  done < <(jq -r '.images[].tar' "${MANIFEST_PATH}")

  while IFS= read -r image_ref; do
    image_refs+=("${image_ref}")
  done < <(jq -r '.images[].ref' "${MANIFEST_PATH}")
else
  shopt -s nullglob
  image_tars=("${IMAGE_ARTIFACT_DIR}"/*.tar)
  shopt -u nullglob
fi

if ((${#image_tars[@]} == 0)); then
  echo "ERROR: no Docker image tar files found in:" >&2
  echo "  ${IMAGE_ARTIFACT_DIR}" >&2
  exit 1
fi

echo "Loading Docker image artifacts:"
for image_tar in "${image_tars[@]}"; do
  if [[ ! -f "${image_tar}" ]]; then
    echo "ERROR: Docker image tar listed in manifest is missing:" >&2
    echo "  ${image_tar}" >&2
    exit 1
  fi

  echo "  ${image_tar}"
  docker load --input "${image_tar}"
done

if ((${#image_refs[@]} > 0)); then
  echo "Verifying loaded Docker image refs:"
  for image_ref in "${image_refs[@]}"; do
    docker image inspect "${image_ref}" >/dev/null
    echo "  ${image_ref}"
  done
fi

echo "Artifact images loaded successfully."
