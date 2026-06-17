#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  package-artifacts.sh [options]

Options:
  --image IMAGE          Docker image to save. May be repeated.
                         Defaults to ARTIFACT_IMAGE_REFS or BASE_IMAGE/BASE_VSCODE_IMAGE.
  --artifact-root DIR   Artifact directory to package. Defaults to artifacts.
  --output FILE         Output tar.gz path. Defaults to artifacts-<toolchain-name>-<version>.tar.gz.
  --pull                Pull missing pullable images before saving. Default.
  --no-pull             Do not pull missing images.
  -h, --help            Show help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars BASE_IMAGE BASE_IMAGE_NAME BASE_IMAGE_VERSION

ARTIFACT_ROOT="${REPO_ROOT}/artifacts"
OUTPUT_IMAGE_NAME="${BASE_TOOLCHAIN_IMAGE_NAME:-${BASE_IMAGE_NAME}}"
OUTPUT_IMAGE_VERSION="${BASE_TOOLCHAIN_IMAGE_VERSION:-${BASE_IMAGE_VERSION}}"
OUTPUT_PATH="${REPO_ROOT}/artifacts-${OUTPUT_IMAGE_NAME}-${OUTPUT_IMAGE_VERSION}.tar.gz"
PULL_MISSING=1
CUSTOM_IMAGES=0
IMAGE_REFS=()

if [[ -n "${ARTIFACT_IMAGE_REFS:-}" ]]; then
  read -r -a IMAGE_REFS <<< "${ARTIFACT_IMAGE_REFS}"
else
  IMAGE_REFS+=("${BASE_IMAGE}")
  if [[ -n "${BASE_VSCODE_IMAGE:-}" ]]; then
    IMAGE_REFS+=("${BASE_VSCODE_IMAGE}")
  fi
fi

while (($# > 0)); do
  case "$1" in
    --image)
      if (($# < 2)); then
        echo "ERROR: --image requires a value." >&2
        usage
        exit 1
      fi
      if [[ "${CUSTOM_IMAGES}" -eq 0 ]]; then
        IMAGE_REFS=()
        CUSTOM_IMAGES=1
      fi
      IMAGE_REFS+=("$2")
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
    --pull)
      PULL_MISSING=1
      shift
      ;;
    --no-pull)
      PULL_MISSING=0
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

if [[ "${OUTPUT_PATH}" != /* ]]; then
  OUTPUT_PATH="${REPO_ROOT}/${OUTPUT_PATH}"
fi

IMAGE_ARTIFACT_DIR="${ARTIFACT_ROOT}/docker-images"
MANIFEST_PATH="${ARTIFACT_ROOT}/manifest.json"

if [[ "${OUTPUT_PATH}" == "${ARTIFACT_ROOT}"/* ]]; then
  echo "ERROR: output archive must not be inside the artifact root, or it would include itself:" >&2
  echo "  ${OUTPUT_PATH}" >&2
  exit 1
fi

if ((${#IMAGE_REFS[@]} == 0)); then
  echo "ERROR: no Docker images were selected for packaging." >&2
  exit 1
fi

safe_image_name() {
  local image_ref="$1"

  image_ref="${image_ref//@/_}"
  image_ref="${image_ref//\//_}"
  image_ref="${image_ref//:/_}"
  printf '%s\n' "${image_ref}"
}

is_pullable_image_ref() {
  local image_ref="$1"

  if image_has_registry "${image_ref}"; then
    return 0
  fi

  case "${image_ref}" in
    docker/*|library/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_image_available() {
  local image_ref="$1"

  if docker image inspect "${image_ref}" >/dev/null 2>&1; then
    return
  fi

  if [[ "${PULL_MISSING}" -eq 1 ]] && is_pullable_image_ref "${image_ref}"; then
    docker pull "${image_ref}"
    return
  fi

  echo "ERROR: Docker image is not available locally:" >&2
  echo "  ${image_ref}" >&2
  if [[ "${PULL_MISSING}" -eq 0 ]]; then
    echo "Pulling is disabled by --no-pull." >&2
  else
    echo "Build it first, or use a registry-qualified image ref that can be pulled." >&2
  fi
  exit 1
}

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Preparing Docker image artifacts:"
printf '  %s\n' "${IMAGE_REFS[@]}"

mkdir -p "${IMAGE_ARTIFACT_DIR}"
manifest_tmp="$(mktemp)"
trap 'rm -f "${manifest_tmp}"' EXIT

jq -n \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg configFile "${CONFIG_FILE}" \
  --arg artifactRoot "$(basename "${ARTIFACT_ROOT}")" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    configFile: $configFile,
    artifactRoot: $artifactRoot,
    images: []
  }' > "${manifest_tmp}"

for image_ref in "${IMAGE_REFS[@]}"; do
  ensure_image_available "${image_ref}"

  safe_name="$(safe_image_name "${image_ref}")"
  image_tar="${IMAGE_ARTIFACT_DIR}/${safe_name}.tar"
  image_tar_name="$(basename "${image_tar}")"
  image_tar_relative="docker-images/${image_tar_name}"

  echo "Saving Docker image artifact:"
  echo "  image:    ${image_ref}"
  echo "  artifact: ${image_tar}"

  docker save --output "${image_tar}" "${image_ref}"
  (
    cd "${IMAGE_ARTIFACT_DIR}"
    sha256sum "${image_tar_name}" > "${image_tar_name}.sha256"
  )
  image_sha256="$(awk '{print $1}' "${image_tar}.sha256")"

  jq \
    --arg ref "${image_ref}" \
    --arg tar "${image_tar_relative}" \
    --arg sha256 "${image_sha256}" \
    '.images += [{
      ref: $ref,
      tar: $tar,
      sha256: $sha256
    }]' \
    "${manifest_tmp}" > "${manifest_tmp}.next"
  mv "${manifest_tmp}.next" "${manifest_tmp}"
done

mv "${manifest_tmp}" "${MANIFEST_PATH}"
trap - EXIT

echo "Wrote artifact manifest:"
echo "  ${MANIFEST_PATH}"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
tar -C "$(dirname "${ARTIFACT_ROOT}")" -czf "${OUTPUT_PATH}" "$(basename "${ARTIFACT_ROOT}")"
(
  cd "$(dirname "${OUTPUT_PATH}")"
  sha256sum "$(basename "${OUTPUT_PATH}")" > "$(basename "${OUTPUT_PATH}").sha256"
)

echo "Packaged artifact directory:"
echo "  ${OUTPUT_PATH}"
echo "  ${OUTPUT_PATH}.sha256"
