#!/usr/bin/env bash
set -euo pipefail

resolve_toolchain_env_file() {
  local repo_root="$1"
  local env_file="${TOOLCHAIN_ENV_FILE:-${repo_root}/config/toolchain.env}"

  if [[ "${env_file}" != /* ]]; then
    env_file="${repo_root}/${env_file}"
  fi

  printf '%s\n' "${env_file}"
}

load_toolchain_env() {
  local repo_root="$1"

  TOOLCHAIN_CONFIG_FILE="$(resolve_toolchain_env_file "${repo_root}")"

  if [[ ! -f "${TOOLCHAIN_CONFIG_FILE}" ]]; then
    echo "ERROR: Toolchain config file not found:"
    echo "  ${TOOLCHAIN_CONFIG_FILE}"
    exit 1
  fi

  # Load docker.env first so toolchain.env can reference UPSTREAM_BASE_IMAGE.
  # shellcheck source=scripts/lib/env.sh
  source "${repo_root}/scripts/lib/env.sh"
  load_env_file "${repo_root}"

  # shellcheck source=/dev/null
  source "${TOOLCHAIN_CONFIG_FILE}"
}

toolchain_abs_path() {
  local repo_root="$1"
  local path_value="$2"

  if [[ "${path_value}" == /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${repo_root}/${path_value}"
  fi
}

toolchain_require_env_vars() {
  local missing=()
  local var_name

  for var_name in "$@"; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("${var_name}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    echo "ERROR: Missing required toolchain config values:"
    printf '  %s\n' "${missing[@]}"
    echo "Toolchain config file:"
    echo "  ${TOOLCHAIN_CONFIG_FILE}"
    exit 1
  fi
}

download_artifact() {
  local url="$1"
  local output="$2"

  mkdir -p "$(dirname "${output}")"
  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --show-error \
    --output "${output}.tmp" \
    "${url}"
  mv "${output}.tmp" "${output}"
}

verify_optional_hash() {
  local algorithm="$1"
  local expected="$2"
  local file_path="$3"

  if [[ -z "${expected}" ]]; then
    return
  fi

  case "${algorithm}" in
    sha256)
      echo "${expected}  ${file_path}" | sha256sum --check --strict
      ;;
    sha512)
      echo "${expected}  ${file_path}" | sha512sum --check --strict
      ;;
    *)
      echo "ERROR: unsupported hash algorithm: ${algorithm}" >&2
      exit 1
      ;;
  esac
}

actual_hash() {
  local algorithm="$1"
  local file_path="$2"

  case "${algorithm}" in
    sha256)
      sha256sum "${file_path}" | awk '{print $1}'
      ;;
    sha512)
      sha512sum "${file_path}" | awk '{print $1}'
      ;;
    *)
      echo "ERROR: unsupported hash algorithm: ${algorithm}" >&2
      exit 1
      ;;
  esac
}

write_tool_metadata() {
  local output="$1"
  local tool="$2"
  local version="$3"
  local platform="$4"
  local url="$5"
  local artifact="$6"
  local hash_algorithm="$7"
  local hash_value="$8"

  jq -n \
    --arg tool "${tool}" \
    --arg version "${version}" \
    --arg platform "${platform}" \
    --arg url "${url}" \
    --arg artifact "${artifact}" \
    --arg hashAlgorithm "${hash_algorithm}" \
    --arg hash "${hash_value}" \
    --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '{
      tool: $tool,
      version: $version,
      platform: $platform,
      url: $url,
      artifact: $artifact,
      hashAlgorithm: $hashAlgorithm,
      hash: $hash,
      generatedAt: $generatedAt
    }' > "${output}"
}
