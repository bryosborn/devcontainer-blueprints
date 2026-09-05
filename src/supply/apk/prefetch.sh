#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_MAP="${SCRIPT_DIR}/package-roots.json"

usage() {
  cat <<'EOF'
Usage: prefetch.sh --config-json PATH --config-sha256 HEX \
  --base-image REPOSITORY@sha256:DIGEST --base-digest sha256:DIGEST \
  --platform linux/amd64 --main-repository URL --extra-repository URL \
  --artifact-root PATH --artifact-lock-root PATH --fragment PATH \
  [--package-map PATH] [--package-set NAME ...]

All inputs are explicit so the top-level lock updater remains the sole mutable
resolution entrypoint. Artifacts are written beneath a platform-qualified root.
EOF
}

config_json=""
config_sha256=""
base_image=""
base_digest=""
platform=""
main_repository=""
extra_repository=""
artifact_root=""
artifact_lock_root=""
fragment=""
package_sets=()

while (($# > 0)); do
  case "$1" in
    --config-json) config_json="${2:-}"; shift 2 ;;
    --config-sha256) config_sha256="${2:-}"; shift 2 ;;
    --base-image) base_image="${2:-}"; shift 2 ;;
    --base-digest) base_digest="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --main-repository) main_repository="${2:-}"; shift 2 ;;
    --extra-repository) extra_repository="${2:-}"; shift 2 ;;
    --artifact-root) artifact_root="${2:-}"; shift 2 ;;
    --artifact-lock-root) artifact_lock_root="${2:-}"; shift 2 ;;
    --fragment) fragment="${2:-}"; shift 2 ;;
    --package-map) PACKAGE_MAP="${2:-}"; shift 2 ;;
    --package-set) package_sets+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value_name in \
  config_json config_sha256 base_image base_digest platform main_repository \
  extra_repository artifact_root artifact_lock_root fragment; do
  if [[ -z "${!value_name}" ]]; then
    echo "ERROR: Missing required option for ${value_name}." >&2
    usage >&2
    exit 2
  fi
done

case "${platform}" in
  linux/amd64|linux/arm64) platform_key="${platform//\//-}" ;;
  *) echo "ERROR: Unsupported platform: ${platform}" >&2; exit 2 ;;
esac

artifact_root="$(realpath -m -- "${artifact_root}")"
platform_output="${artifact_root}/${platform_key}"
platform_lock_root="${artifact_lock_root%/}/${platform_key}"

mkdir -p -- "${artifact_root}" "$(dirname -- "${fragment}")"
staging_platform="$(mktemp -d "${artifact_root}/.${platform_key}.stage.XXXXXXXX")"
apk_output="${staging_platform}/apk"
base_output="${staging_platform}/docker-images"
base_metadata="${staging_platform}/base-image.artifact.json"
staging_fragment="${staging_platform}/apk-resolution.fragment.json"

cleanup() {
  case "${staging_platform}" in
    "${artifact_root}/.${platform_key}.stage."*) rm -rf -- "${staging_platform}" ;;
    *) echo "ERROR: Refusing to remove unexpected staging path: ${staging_platform}" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

python3 "${SCRIPT_DIR}/materialize-base-image.py" \
  --pinned-image "${base_image}" \
  --expected-digest "${base_digest}" \
  --platform "${platform}" \
  --output-dir "${base_output}" \
  --artifact-directory "${platform_lock_root}" \
  --metadata "${base_metadata}"

resolver_args=(
  --config-json "${config_json}"
  --config-sha256 "${config_sha256}"
  --base-image "${base_image}"
  --base-digest "${base_digest}"
  --base-image-metadata "${base_metadata}"
  --platform "${platform}"
  --main-repository "${main_repository}"
  --extra-repository "${extra_repository}"
  --package-map "${PACKAGE_MAP}"
  --output-dir "${apk_output}"
  --artifact-directory "${platform_lock_root}/apk"
  --fragment "${staging_fragment}"
)
for package_set in "${package_sets[@]}"; do
  resolver_args+=(--package-set "${package_set}")
done

python3 "${SCRIPT_DIR}/resolve-apks.py" "${resolver_args[@]}"

python3 "${SCRIPT_DIR}/promote-artifacts.py" \
  --staging-platform "${staging_platform}" \
  --destination-platform "${platform_output}" \
  --fragment-source "${staging_fragment}" \
  --fragment-destination "${fragment}"

echo "Wolfi signed artifact resolution complete."
echo "  platform artifacts: ${platform_output}"
echo "  resolver fragment:  ${fragment}"
