#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: build-image.sh [options]

Options:
  --config FILE                 Wolfi build YAML.
  --lock FILE                   Verified Wolfi lock JSON.
  --apk-artifacts DIR           APK build-context root.
  --repository-subdir PATH      Signed repository below the APK context.
  --packages "PKG=VER ..."      Exact package constraints (resolver testing).
  --image REF                   Output image reference.
  --base-image REF              Digest-pinned input image (resolver testing).
  --platform OS/ARCH            Target platform.
  --user NAME                   Named OCI/remote user.
  --uid UID                     Initial remote-user UID.
  --gid GID                     Initial remote-user GID.
  --keep-workspace              Preserve the generated build workspace.
  -h, --help                    Show this help.

Normal use verifies the YAML/lock pair and consumes:
  .resolved.baseImage.pinnedReference
  .resolved.apk.packageSets.dod.packages (or .roots), or resolver-wide
  .resolved.apk.{roots,packages} records whose DOD roots use module "dod"
  .resolved.apk.packageSets.dod.artifactDirectory (optional)
  .resolved.apk.packageSets.dod.repositorySubdir (optional)

Package entries may be exact strings, {"constraint":"..."}, or
{"name":"...","version":"..."}. The APK context must contain a signed
APKINDEX.tar.gz at <context>/<repository-subdir> and every locked APK needed by
the package closure. Docker networking is disabled for the complete build.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_ROOT}/../../.." && pwd)"
CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"
CONFIG_TOOL="${REPO_ROOT}/scripts/wolfi/config.mjs"

APK_ARTIFACTS=""
REPOSITORY_SUBDIR=""
PACKAGE_CONSTRAINTS=""
IMAGE_REF=""
BASE_IMAGE=""
PLATFORM=""
REMOTE_USER=""
REMOTE_UID=""
REMOTE_GID=""
KEEP_WORKSPACE=false

while (($# > 0)); do
  case "$1" in
    --config|--lock|--apk-artifacts|--repository-subdir|--packages|--image|--base-image|--platform|--user|--uid|--gid)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      case "${option}" in
        --config) CONFIG_FILE="${value}" ;;
        --lock) LOCK_FILE="${value}" ;;
        --apk-artifacts) APK_ARTIFACTS="${value}" ;;
        --repository-subdir) REPOSITORY_SUBDIR="${value}" ;;
        --packages) PACKAGE_CONSTRAINTS="${value}" ;;
        --image) IMAGE_REF="${value}" ;;
        --base-image) BASE_IMAGE="${value}" ;;
        --platform) PLATFORM="${value}" ;;
        --user) REMOTE_USER="${value}" ;;
        --uid) REMOTE_UID="${value}" ;;
        --gid) REMOTE_GID="${value}" ;;
      esac
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

for command_name in devcontainer docker jq sha256sum; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  fi
done

for path_name in CONFIG_FILE LOCK_FILE; do
  path_value="${!path_name}"
  if [[ "${path_value}" != /* ]]; then
    printf -v "${path_name}" '%s/%s' "${REPO_ROOT}" "${path_value}"
  fi
done

[[ -f "${CONFIG_TOOL}" ]] || {
  echo "ERROR: Wolfi config tool is missing: ${CONFIG_TOOL}" >&2
  exit 1
}
[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: Wolfi build config is missing: ${CONFIG_FILE}" >&2
  exit 1
}
[[ -f "${LOCK_FILE}" ]] || {
  echo "ERROR: Wolfi build lock is missing: ${LOCK_FILE}" >&2
  exit 1
}

# shellcheck source=scripts/wolfi/lib.sh
source "${REPO_ROOT}/scripts/wolfi/lib.sh"
wolfi_verify_lock "${REPO_ROOT}" "${CONFIG_FILE}" "${LOCK_FILE}"

IMAGE_REF="${IMAGE_REF:-$(jq -er '.images.dod.reference' "${LOCK_FILE}")}"
LOCKED_BASE_IMAGE="$(jq -er '
  .resolved.apk.baseImage.artifact.localReference
  // .resolved.baseImage.pinnedReference
' "${LOCK_FILE}")"
BASE_IMAGE="${BASE_IMAGE:-${LOCKED_BASE_IMAGE}}"
PLATFORM="${PLATFORM:-$(jq -er '.config.images.platform' "${LOCK_FILE}")}"
REMOTE_USER="${REMOTE_USER:-$(jq -er '.config.user.name' "${LOCK_FILE}")}"
REMOTE_UID="${REMOTE_UID:-$(jq -er '.config.user.uid | tostring' "${LOCK_FILE}")}"
REMOTE_GID="${REMOTE_GID:-$(jq -er '.config.user.gid | tostring' "${LOCK_FILE}")}"

if [[ -z "${PACKAGE_CONSTRAINTS}" ]]; then
  package_json="$(jq -ce \
    '.resolved.apk.packageSets.dod.roots // .resolved.apk.packageSets.dod.packages' \
    "${LOCK_FILE}" 2>/dev/null || true)"
  if [[ -z "${package_json}" || "${package_json}" == "null" ]]; then
    package_json="$(jq -ce '
      .resolved.apk as $apk
      | ($apk.roots // [] | map(select(.module == "dod")) | map(.name)) as $roots
      | if ($roots | length) == 0 then
          error("no resolver-wide DOD roots")
        else
          $roots | map(. as $name
            | ($apk.packages // [] | map(select(.name == $name))) as $matches
            | if ($matches | length) != 1 then
                error("DOD root must resolve exactly once: " + $name)
              else
                {name: $name, version: $matches[0].version}
              end)
        end
    ' "${LOCK_FILE}" 2>/dev/null || true)"
    if [[ -z "${package_json}" || "${package_json}" == "null" ]]; then
      echo "ERROR: Lockfile has no resolved APK package set for the DOD layer." >&2
      echo "Expected packageSets.dod or resolver-wide roots with module=\"dod\"." >&2
      exit 1
    fi
  fi
  PACKAGE_CONSTRAINTS="$(jq -er '
    if type != "array" or length == 0 then
      error("DOD package set must be a non-empty array")
    else
      map(
        if type == "string" then .
        elif type == "object" and (.constraint | type) == "string" then .constraint
        elif type == "object" and (.name | type) == "string" and (.version | type) == "string"
          then "\(.name)=\(.version)"
        else error("unsupported DOD package entry")
        end
      ) | join(" ")
    end
  ' <<< "${package_json}")"
fi

read -r -a package_array <<< "${PACKAGE_CONSTRAINTS}"
if ((${#package_array[@]} == 0)); then
  echo "ERROR: DOD package set is empty." >&2
  exit 1
fi
for package_constraint in "${package_array[@]}"; do
  if [[ ! "${package_constraint}" =~ ^[A-Za-z0-9_+.@~-]+=[A-Za-z0-9_+.~:-]+$ ]]; then
    echo "ERROR: DOD package is not an exact, safe APK constraint: ${package_constraint}" >&2
    exit 1
  fi
done
PACKAGE_CONSTRAINTS="${package_array[*]}"

REPOSITORY_SUBDIR="${REPOSITORY_SUBDIR:-$(jq -r \
  '.resolved.apk.packageSets.dod.repositorySubdir // "repositories/main"' \
  "${LOCK_FILE}")}"
if [[ "${REPOSITORY_SUBDIR}" == /* || "${REPOSITORY_SUBDIR}" == *..* || \
      "${REPOSITORY_SUBDIR}" == *$'\n'* ]]; then
  echo "ERROR: Unsafe APK repository subdirectory: ${REPOSITORY_SUBDIR}" >&2
  exit 1
fi

if [[ -z "${APK_ARTIFACTS}" ]]; then
  APK_ARTIFACTS="$(jq -r \
    '.resolved.apk.packageSets.dod.artifactDirectory // .resolved.apk.artifactDirectory // empty' \
    "${LOCK_FILE}")"
fi
if [[ -z "${APK_ARTIFACTS}" ]]; then
  artifact_root="$(jq -er '.config.artifacts.root' "${LOCK_FILE}")"
  platform_slug="${PLATFORM//\//-}"
  APK_ARTIFACTS="${artifact_root}/${platform_slug}/apk"
fi
if [[ "${APK_ARTIFACTS}" != /* ]]; then
  APK_ARTIFACTS="${REPO_ROOT}/${APK_ARTIFACTS}"
fi
APK_ARTIFACTS="$(realpath -m -- "${APK_ARTIFACTS}")"

[[ -d "${APK_ARTIFACTS}" ]] || {
  echo "ERROR: Frozen DOD APK artifact context is missing: ${APK_ARTIFACTS}" >&2
  exit 1
}
case "${PLATFORM}" in
  linux/amd64) apk_architecture=x86_64 ;;
  linux/arm64) apk_architecture=aarch64 ;;
  *)
    echo "ERROR: Unsupported Wolfi target platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac
[[ -f "${APK_ARTIFACTS}/${REPOSITORY_SUBDIR}/${apk_architecture}/APKINDEX.tar.gz" ]] || {
  echo "ERROR: Signed APK index is missing:" >&2
  echo "  ${APK_ARTIFACTS}/${REPOSITORY_SUBDIR}/${apk_architecture}/APKINDEX.tar.gz" >&2
  exit 1
}

if [[ "${BASE_IMAGE}" != "$(jq -r '.resolved.apk.baseImage.artifact.localReference // empty' "${LOCK_FILE}")" \
      && ! "${BASE_IMAGE}" =~ @sha256:[a-f0-9]{64}$ ]]; then
  echo "ERROR: Base image must be the locked local snapshot or a digest-pinned reference: ${BASE_IMAGE}" >&2
  exit 1
fi
[[ "${REMOTE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "ERROR: Invalid named remote user: ${REMOTE_USER}" >&2
  exit 1
}
for identity_value in "${REMOTE_UID}" "${REMOTE_GID}"; do
  if [[ ! "${identity_value}" =~ ^[0-9]+$ ]] || ((identity_value < 1 || identity_value > 2147483647)); then
    echo "ERROR: Invalid UID/GID value: ${identity_value}" >&2
    exit 1
  fi
done

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Digest-pinned Wolfi base image is not in the local Docker store:" >&2
  echo "  ${BASE_IMAGE}" >&2
  echo "Load the locked base-image artifact before building." >&2
  exit 1
fi

mkdir -p "${REPO_ROOT}/.tmp"
BUILD_WORKSPACE="$(mktemp -d "${REPO_ROOT}/.tmp/wolfi-base-dod.XXXXXXXX")"
cleanup() {
  if [[ "${KEEP_WORKSPACE}" == true ]]; then
    echo "Preserved build workspace: ${BUILD_WORKSPACE}"
  else
    rm -rf -- "${BUILD_WORKSPACE}"
  fi
}
trap cleanup EXIT

cp -a "${SOURCE_ROOT}/." "${BUILD_WORKSPACE}/"
generated_config="${BUILD_WORKSPACE}/.devcontainer/devcontainer.json"
jq \
  --arg base_image "${BASE_IMAGE}" \
  --arg remote_user "${REMOTE_USER}" \
  --arg remote_uid "${REMOTE_UID}" \
  --arg remote_gid "${REMOTE_GID}" \
  --arg repository_subdir "${REPOSITORY_SUBDIR}" \
  --arg packages "${PACKAGE_CONSTRAINTS}" \
  --arg apk_artifacts "${APK_ARTIFACTS}" \
  '.build.args.BASE_IMAGE = $base_image
   | .build.args.REMOTE_USER = $remote_user
   | .build.args.REMOTE_UID = $remote_uid
   | .build.args.REMOTE_GID = $remote_gid
   | .build.args.WOLFI_APK_REPOSITORY_SUBDIR = $repository_subdir
   | .build.args.WOLFI_DOD_APK_PACKAGES = $packages
   | .build.options = ["--network=none", "--build-context", "wolfi_apks=" + $apk_artifacts]
   | .remoteUser = $remote_user' \
  "${generated_config}" > "${generated_config}.tmp"
mv -f -- "${generated_config}.tmp" "${generated_config}"

echo "Building Wolfi DOD image offline:"
echo "  image:       ${IMAGE_REF}"
echo "  base:        ${BASE_IMAGE}"
echo "  platform:    ${PLATFORM}"
echo "  APK context: ${APK_ARTIFACTS}"
echo "  user:        ${REMOTE_USER} (${REMOTE_UID}:${REMOTE_GID})"

devcontainer build \
  --workspace-folder "${BUILD_WORKSPACE}" \
  --config "${generated_config}" \
  --image-name "${IMAGE_REF}" \
  --platform "${PLATFORM}" \
  --no-lockfile

actual_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE_REF}")"
actual_user="$(docker image inspect --format '{{.Config.User}}' "${IMAGE_REF}")"
metadata="$(docker image inspect --format '{{index .Config.Labels "devcontainer.metadata"}}' "${IMAGE_REF}")"

[[ "${actual_platform}" == "${PLATFORM}" ]] || {
  echo "ERROR: Built platform ${actual_platform} does not match ${PLATFORM}." >&2
  exit 1
}
[[ "${actual_user}" == "${REMOTE_USER}" ]] || {
  echo "ERROR: OCI image user is ${actual_user}, expected named user ${REMOTE_USER}." >&2
  exit 1
}
jq -e --arg user "${REMOTE_USER}" '
  (if type == "array" then . else [.] end) as $items
  | any($items[]; .containerUser? == "root")
    and any($items[]; .remoteUser? == $user)
    and any($items[]; .updateRemoteUserUID? == true)
    and any($items[]; .init? == true)
    and any($items[]; .entrypoint? == "/usr/local/share/wolfi-dod/docker-socket-proxy-entrypoint.sh")
' <<< "${metadata}" >/dev/null || {
  echo "ERROR: Built image is missing required merged Dev Container metadata." >&2
  exit 1
}

echo "Built and verified Wolfi DOD image: ${IMAGE_REF}"
