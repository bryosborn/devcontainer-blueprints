#!/usr/bin/env bash
# Shared, side-effect-free helpers for Wolfi workflows.

wolfi_repo_root() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}

wolfi_abs_path() {
  local repo_root="$1"
  local value="$2"
  if [[ "${value}" == /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s/%s\n' "${repo_root}" "${value}"
  fi
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
    echo "ERROR: Wolfi build configuration is missing: ${config_file}" >&2
    return 1
  }
  [[ -f "${lock_file}" ]] || {
    echo "ERROR: Wolfi build lock is missing: ${lock_file}" >&2
    return 1
  }

  # Connected development environments get full schema and semantic checking.
  # Disconnected machines need only jq: the raw source hash is deliberately
  # stricter than the semantic hash and catches any YAML drift without a parser.
  if command -v node >/dev/null 2>&1 \
      && [[ -f "${repo_root}/node_modules/yaml/package.json" ]]; then
    node "${repo_root}/scripts/wolfi/config.mjs" \
      verify-lock "${config_file}" "${lock_file}" >/dev/null
    return
  fi

  jq -e '
    .schemaVersion == 1
    and (.source.fileSha256 | type == "string" and test("^[a-f0-9]{64}$"))
    and (.source.semanticSha256 | type == "string" and test("^[a-f0-9]{64}$"))
    and (.config | type == "object")
    and (.images | type == "object")
    and (.resolved.baseImage.pinnedReference | type == "string")
  ' "${lock_file}" >/dev/null || {
    echo "ERROR: Wolfi lock has an invalid frozen/offline shape: ${lock_file}" >&2
    return 1
  }
  expected_file_hash="$(jq -er '.source.fileSha256' "${lock_file}")"
  actual_file_hash="$(sha256sum "${config_file}" | awk '{print $1}')"
  if [[ "${actual_file_hash}" != "${expected_file_hash}" ]]; then
    echo "ERROR: Wolfi YAML differs from its lock; run ./scripts/wolfi/update-lock.sh." >&2
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

wolfi_apk_arch() {
  case "$1" in
    linux/amd64) printf '%s\n' x86_64 ;;
    linux/arm64) printf '%s\n' aarch64 ;;
    *) echo "ERROR: Unsupported Wolfi platform: $1" >&2; return 1 ;;
  esac
}
