#!/usr/bin/env bash
# Shared env-file handling for local scripts.

resolve_env_file() {
  local repo_root="$1"
  local env_file="${DOCKER_ENV_FILE:-${repo_root}/docker.env}"

  if [[ "${env_file}" != /* ]]; then
    env_file="${repo_root}/${env_file}"
  fi

  printf '%s\n' "${env_file}"
}

load_env_file() {
  local repo_root="$1"

  CONFIG_FILE="$(resolve_env_file "${repo_root}")"

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found:"
    echo "  ${CONFIG_FILE}"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
}

require_env_vars() {
  local missing=()
  local var_name

  for var_name in "$@"; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("${var_name}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    echo "ERROR: Missing required config values:"
    printf '  %s\n' "${missing[@]}"
    echo "Config file:"
    echo "  ${CONFIG_FILE}"
    exit 1
  fi
}

image_has_registry() {
  local image_ref="$1"
  local first_component="${image_ref%%/*}"

  [[ "${image_ref}" == */* ]] \
    && [[ "${first_component}" == *.* || "${first_component}" == *:* || "${first_component}" == "localhost" ]]
}
