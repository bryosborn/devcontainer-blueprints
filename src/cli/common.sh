#!/usr/bin/env bash
# Shared, side-effect-free helpers for internal image commands.

wolfi_abs_path() {
  local repo_root="$1"
  local value="$2"
  if [[ "${value}" == /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s/%s\n' "${repo_root}" "${value}"
  fi
}

# Set the standard path variables once so every command uses the selected
# profile and its own companion lock. Explicit --lock values remain supported.
wolfi_init_paths() {
  local repo_root="$1"
  local config_file="${2:-}"
  local lock_file="${3:-}"
  [[ -n "${config_file}" ]] || {
    echo "ERROR: an internal command requires a selected profile configuration." >&2
    return 2
  }
  CONFIG_FILE="$(wolfi_abs_path "${repo_root}" "${config_file}")"
  if [[ -z "${lock_file}" ]]; then
    case "${CONFIG_FILE,,}" in
      *.yaml|*.yml) LOCK_FILE="${CONFIG_FILE%.*}.lock.json" ;;
      *) LOCK_FILE="${CONFIG_FILE}.lock.json" ;;
    esac
  else
    LOCK_FILE="$(wolfi_abs_path "${repo_root}" "${lock_file}")"
  fi
  export CONFIG_FILE LOCK_FILE
}

wolfi_require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "ERROR: Required command not found: ${command_name}" >&2
      return 1
    fi
  done
}

wolfi_verify_lock() {
  local repo_root="$1"
  local config_file="$2"
  local lock_file="$3"
  local expected_file_hash actual_file_hash

  wolfi_require_commands jq sha256sum
  [[ -f "${config_file}" ]] || {
    echo "ERROR: image configuration is missing: ${config_file}" >&2
    return 1
  }
  [[ -f "${lock_file}" ]] || {
    echo "ERROR: image lock is missing: ${lock_file}" >&2
    return 1
  }

  # Connected development environments get full schema and semantic checking.
  # Disconnected machines need only jq: the raw source hash is deliberately
  # stricter than the semantic hash and catches any YAML drift without a parser.
  if command -v node >/dev/null 2>&1 \
      && [[ -f "${repo_root}/node_modules/yaml/package.json" ]]; then
    node "${repo_root}/src/config/config.mjs" \
      verify-lock "${config_file}" "${lock_file}" >/dev/null
    return
  fi

  jq -e '
    def vendor_record($key; $enabled):
      if $enabled then
        (.resolved[$key] | type == "object" and length > 0)
      else
        (.resolved | has($key) | not)
      end;
    .schemaVersion == 3
    and (.source.fileSha256 | type == "string" and test("^[a-f0-9]{64}$"))
    and (.source.semanticSha256 | type == "string" and test("^[a-f0-9]{64}$"))
    and (.source.settingsFileSha256 | type == "string" and test("^[a-f0-9]{64}$"))
    and (.config | type == "object")
    and (.image | type == "object")
    and .image == .config.image
    and .config.schemaVersion == 3
    and (.config | has("toolchain") | not)
    and (.config.build | type == "object")
    and (.config.utilities | type == "object")
    and vendor_record("kaniko"; (.config | has("kaniko")))
    and vendor_record("playwright"; (.config | has("playwright")))
    and (if .config | has("kaniko") then
      .resolved.kaniko.version == .config.kaniko.version and .resolved.kaniko.platform == .image.platform else true end)
    and (if .config | has("playwright") then
      .resolved.playwright.version == .config.playwright.version and .resolved.playwright.platform == .image.platform else true end)
    and (.image.platform == "linux/amd64" or .image.platform == "linux/arm64")
    and (.resolved.baseImage.pinnedReference | type == "string")
    and vendor_record("vscode"; (.config | has("vscode")))
    and vendor_record("extensions"; ((.config.vscode.extensions // []) | length > 0))
    and vendor_record("kubectl"; ((.config.utilities // {}) | has("kubectl")))
    and vendor_record("rust"; ((.config.build // {}) | has("rust")))
    and (.resolved.apk | type == "object" and length > 0)
    and (.resolved.apk.packageSets | type == "object" and keys == ["final"])
    and (.resolved.apk.packageSets.final | type == "object" and length > 0)
    and (.resolved.apk.packageSets.final.artifactDirectory | type == "string" and length > 0)
    and (.resolved.apk.packageSets.final | [.closure, .roots, .modules, .packages, .repositorySubdirs]
      | all(.[]; type == "array" and length > 0))
  ' "${lock_file}" >/dev/null || {
    echo "ERROR: Wolfi lock has an invalid frozen/offline shape: ${lock_file}" >&2
    return 1
  }
  expected_file_hash="$(jq -er '.source.fileSha256' "${lock_file}")"
  actual_file_hash="$(sha256sum "${config_file}" | awk '{print $1}')"
  if [[ "${actual_file_hash}" != "${expected_file_hash}" ]]; then
    echo "ERROR: profile YAML differs from its lock; run ./scripts/images.sh update-lock all." >&2
    return 1
  fi
  expected_file_hash="$(jq -er '.source.settingsFileSha256' "${lock_file}")"
  actual_file_hash="$(sha256sum "${repo_root}/config/images.env" | awk '{print $1}')"
  if [[ "${actual_file_hash}" != "${expected_file_hash}" ]]; then
    echo "ERROR: config/images.env differs from the lock; run ./scripts/images.sh update-lock all." >&2
    return 1
  fi
}

# This label binds a built image to the exact generated lockfile bytes. It is
# intentionally distinct from the YAML semantic/source hashes stored inside
# the lock: a resolver refresh with unchanged user configuration must still
# make every image built from the previous resolution stale.
WOLFI_LOCK_SHA256_LABEL="devcontainer-blueprints.lock.sha256"

wolfi_lock_sha256() {
  local lock_file="$1"
  local lock_sha256

  wolfi_require_commands sha256sum
  [[ -f "${lock_file}" ]] || {
    echo "ERROR: image lock is missing: ${lock_file}" >&2
    return 1
  }
  lock_sha256="$(sha256sum "${lock_file}" | awk '{print $1}')"
  if [[ ! "${lock_sha256}" =~ ^[a-f0-9]{64}$ ]]; then
    echo "ERROR: could not calculate a valid SHA256 for image lock: ${lock_file}" >&2
    return 1
  fi
  printf '%s\n' "${lock_sha256}"
}

wolfi_verify_image_lock() {
  local image_ref="$1"
  local lock_file="$2"
  local expected_sha256 actual_sha256 expected_config expected_settings actual_config actual_settings

  wolfi_require_commands docker sha256sum
  expected_sha256="$(wolfi_lock_sha256 "${lock_file}")"
  if ! docker image inspect "${image_ref}" >/dev/null 2>&1; then
    echo "ERROR: required image is not available locally: ${image_ref}" >&2
    return 1
  fi
  actual_sha256="$(docker image inspect --format \
    '{{index .Config.Labels "devcontainer-blueprints.lock.sha256"}}' \
    "${image_ref}")"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo "ERROR: image ${image_ref} was not built from the current exact lock bytes." >&2
    echo "  image ${WOLFI_LOCK_SHA256_LABEL}: ${actual_sha256:-<missing>}" >&2
    echo "  current lock SHA256: ${expected_sha256}" >&2
    echo "Rebuild the image before testing or generating evidence." >&2
    return 1
  fi
  expected_config="$(jq -er '.source.fileSha256' "${lock_file}")"
  expected_settings="$(jq -er '.source.settingsFileSha256' "${lock_file}")"
  actual_config="$(docker image inspect --format '{{index .Config.Labels "devcontainer-blueprints.config.sha256"}}' "${image_ref}")"
  actual_settings="$(docker image inspect --format '{{index .Config.Labels "devcontainer-blueprints.settings.sha256"}}' "${image_ref}")"
  if [[ "${actual_config}" != "${expected_config}" || "${actual_settings}" != "${expected_settings}" ]]; then
    echo "ERROR: image ${image_ref} does not carry the current YAML and naming-setting hashes." >&2
    return 1
  fi
}

wolfi_platform_slug() {
  case "$1" in
    linux/amd64) printf '%s\n' linux-amd64 ;;
    linux/arm64) printf '%s\n' linux-arm64 ;;
    *) echo "ERROR: Unsupported Wolfi platform: $1" >&2; return 1 ;;
  esac
}
