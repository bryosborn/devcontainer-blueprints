#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/wolfi/update-lock.sh [options]

Options:
  --config PATH           Source YAML (required).
  --lock PATH             Generated lock (default: selected YAML basename + .lock.json).
  --resolution-file PATH  Add an advanced resolver fragment (repeatable).
  --keep-workspace        Preserve intermediate resolver files under .tmp/.
  -h, --help              Show this help.

This is the only Wolfi command that resolves mutable selectors. It refreshes
the base-image digest, signed APK closure, VS Code/Marketplace payloads,
kubectl, and Rust artifact bundle before atomically replacing the committed
lock. Normal prefetch and build commands consume only those frozen results.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE=""
LOCK_FILE=""
KEEP_WORKSPACE=false
EXTRA_FRAGMENTS=()

while (($# > 0)); do
  case "$1" in
    --config|--lock|--resolution-file)
      if (($# < 2)); then
        echo "ERROR: $1 requires a path." >&2
        usage >&2
        exit 2
      fi
      case "$1" in
        --config) CONFIG_FILE="$2" ;;
        --lock) LOCK_FILE="$2" ;;
        --resolution-file) EXTRA_FRAGMENTS+=("$2") ;;
      esac
      shift 2
      ;;
    --keep-workspace)
      KEEP_WORKSPACE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# shellcheck source=scripts/wolfi/lib.sh
source "${SCRIPT_DIR}/lib.sh"
wolfi_init_paths "${REPO_ROOT}" "${CONFIG_FILE}" "${LOCK_FILE}"
wolfi_require_commands docker jq node npm python3 sha256sum

[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: Wolfi build configuration is missing: ${CONFIG_FILE}" >&2
  exit 1
}
if [[ ! -f "${REPO_ROOT}/node_modules/yaml/package.json" ]]; then
  echo "ERROR: Node dependencies are missing. Run 'npm ci' before updating the Wolfi lock." >&2
  exit 1
fi

mkdir -p "${REPO_ROOT}/.tmp" "$(dirname -- "${LOCK_FILE}")"
WORKSPACE="$(mktemp -d "${REPO_ROOT}/.tmp/wolfi-lock.XXXXXXXX")"
cleanup() {
  if [[ "${KEEP_WORKSPACE}" == true ]]; then
    echo "Preserved resolver workspace: ${WORKSPACE}"
  else
    rm -rf -- "${WORKSPACE}"
  fi
}
trap cleanup EXIT

CONFIG_JSON="${WORKSPACE}/config.normalized.json"
BASE_LOCK="${WORKSPACE}/base.lock.json"
APK_FRAGMENT="${WORKSPACE}/apk.fragment.json"
VENDOR_FRAGMENT="${WORKSPACE}/vendor.fragment.json"

node "${SCRIPT_DIR}/config.mjs" print-json "${CONFIG_FILE}" > "${CONFIG_JSON}"
CONFIG_HASH="$(node "${SCRIPT_DIR}/config.mjs" hash "${CONFIG_FILE}")"

# Resolve the rolling OCI selector once. The final lock reuses this verified
# intermediate so a tag move during a long Marketplace resolution cannot mix
# two different base snapshots.
node "${SCRIPT_DIR}/update-lock.mjs" \
  --config "${CONFIG_FILE}" \
  --lock "${BASE_LOCK}" \
  --base-only

BASE_IMAGE="$(jq -er '.resolved.baseImage.pinnedReference' "${BASE_LOCK}")"
BASE_DIGEST="$(jq -er '.resolved.baseImage.digest' "${BASE_LOCK}")"
PLATFORM="$(jq -er '.image.platform' "${CONFIG_JSON}")"
ARTIFACT_LOCK_ROOT="$(jq -er '.artifacts.root' "${CONFIG_JSON}")"
MAIN_REPOSITORY="$(jq -er '.wolfi.repositories.main' "${CONFIG_JSON}")"
EXTRA_REPOSITORY="$(jq -er '.wolfi.repositories.extra' "${CONFIG_JSON}")"
ARTIFACT_ROOT="$(wolfi_abs_path "${REPO_ROOT}" "${ARTIFACT_LOCK_ROOT}")"

"${REPO_ROOT}/src/wolfi/apk-artifacts/scripts/prefetch.sh" \
  --config-json "${CONFIG_JSON}" \
  --config-sha256 "${CONFIG_HASH}" \
  --base-image "${BASE_IMAGE}" \
  --base-digest "${BASE_DIGEST}" \
  --platform "${PLATFORM}" \
  --main-repository "${MAIN_REPOSITORY}" \
  --extra-repository "${EXTRA_REPOSITORY}" \
  --artifact-root "${ARTIFACT_ROOT}" \
  --artifact-lock-root "${ARTIFACT_LOCK_ROOT}" \
  --fragment "${APK_FRAGMENT}"

PLATFORM_SLUG="$(wolfi_platform_slug "${PLATFORM}")"
UPDATE_ARGS=(
  --config "${CONFIG_FILE}"
  --lock "${LOCK_FILE}"
  --base-lock "${BASE_LOCK}"
  --resolution-file "${APK_FRAGMENT}"
)
if jq -e 'has("vscode") or has("kaniko") or has("playwright") or (.utilities | has("kubectl")) or (.build | has("rust"))' "${CONFIG_JSON}" >/dev/null; then
  python3 "${REPO_ROOT}/src/wolfi/vendor-artifacts/scripts/resolve-vendor.py" \
    --config-json "${CONFIG_JSON}" \
    --config-hash "${CONFIG_HASH}" \
    --base-image "${BASE_IMAGE}" \
    --artifact-root "${ARTIFACT_ROOT}/${PLATFORM_SLUG}/vendor" \
    --fragment "${VENDOR_FRAGMENT}" \
    --repo-root "${REPO_ROOT}"
  if jq -e '.resolved | length > 0' "${VENDOR_FRAGMENT}" >/dev/null; then
    UPDATE_ARGS+=(--resolution-file "${VENDOR_FRAGMENT}")
  fi
fi
for fragment in "${EXTRA_FRAGMENTS[@]}"; do
  UPDATE_ARGS+=(--resolution-file "${fragment}")
done
node "${SCRIPT_DIR}/update-lock.mjs" "${UPDATE_ARGS[@]}"
node "${SCRIPT_DIR}/config.mjs" verify-lock "${CONFIG_FILE}" "${LOCK_FILE}" >/dev/null

echo "Wolfi lock update complete:"
echo "  config:    ${CONFIG_FILE}"
echo "  lock:      ${LOCK_FILE}"
echo "  artifacts: ${ARTIFACT_ROOT}/${PLATFORM_SLUG}"
