#!/usr/bin/env bash
# Shared env-file and target-platform handling for local scripts.

configure_target_platform() {
  case "${DOCKER_PLATFORM:-}" in
    linux/amd64)
      TARGET_ARCH="amd64"
      TARGET_VSCODE_CLIENT_PLATFORM="linux-x64"
      TARGET_VSCODE_SERVER_PLATFORM="server-linux-x64"
      TARGET_VSCODE_EXTENSION_PLATFORM="linux-x64"
      TARGET_TOOLCHAIN_PLATFORM="linux-x64"
      TARGET_RUST_TRIPLE="x86_64-unknown-linux-gnu"
      ;;
    linux/arm64)
      TARGET_ARCH="arm64"
      TARGET_VSCODE_CLIENT_PLATFORM="linux-arm64"
      TARGET_VSCODE_SERVER_PLATFORM="server-linux-arm64"
      TARGET_VSCODE_EXTENSION_PLATFORM="linux-arm64"
      TARGET_TOOLCHAIN_PLATFORM="linux-arm64"
      TARGET_RUST_TRIPLE="aarch64-unknown-linux-gnu"
      ;;
    "")
      echo "ERROR: Missing required config value: DOCKER_PLATFORM" >&2
      echo "Config file:" >&2
      echo "  ${CONFIG_FILE}" >&2
      exit 1
      ;;
    *)
      echo "ERROR: Unsupported DOCKER_PLATFORM: ${DOCKER_PLATFORM}" >&2
      echo "Supported values: linux/amd64, linux/arm64" >&2
      exit 1
      ;;
  esac

  export \
    DOCKER_DEFAULT_PLATFORM="${DOCKER_PLATFORM}" \
    TARGET_ARCH \
    TARGET_VSCODE_CLIENT_PLATFORM \
    TARGET_VSCODE_SERVER_PLATFORM \
    TARGET_VSCODE_EXTENSION_PLATFORM \
    TARGET_TOOLCHAIN_PLATFORM \
    TARGET_RUST_TRIPLE

  # These build arguments are target-derived rather than independently
  # configured, preventing a server archive from drifting from its image.
  BASE_VSCODE_CLIENT_PLATFORM="${TARGET_VSCODE_CLIENT_PLATFORM}"
  BASE_VSCODE_SERVER_PLATFORM="${TARGET_VSCODE_SERVER_PLATFORM}"
  TOOLCHAIN_PLATFORM="${TARGET_TOOLCHAIN_PLATFORM}"
  TOOLCHAIN_ARCH="${TARGET_ARCH}"
  RUST_TARGET_TRIPLE="${TARGET_RUST_TRIPLE}"
  export \
    BASE_VSCODE_CLIENT_PLATFORM \
    BASE_VSCODE_SERVER_PLATFORM \
    TOOLCHAIN_PLATFORM \
    TOOLCHAIN_ARCH \
    RUST_TARGET_TRIPLE
}

resolve_env_file() {
  local repo_root="$1"
  local env_file="${DOCKER_ENV_FILE:-${repo_root}/config/docker.env}"

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
  configure_target_platform
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

assert_local_image_platform() {
  local image_ref="$1"
  local actual_platform

  actual_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}" 2>/dev/null || true)"
  if [[ "${actual_platform}" != "${DOCKER_PLATFORM}" ]]; then
    echo "ERROR: Docker image platform does not match DOCKER_PLATFORM." >&2
    echo "  image:    ${image_ref}" >&2
    echo "  expected: ${DOCKER_PLATFORM}" >&2
    echo "  actual:   ${actual_platform:-not available}" >&2
    exit 1
  fi
}
