#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: install-packages.sh --mirror DIR --architecture ARCH \
  --repository-subdirs "DIR ..." --packages "NAME=VERSION ..."

Installs exact APK constraints from signed, local Wolfi repository snapshots.
Network access and untrusted packages are never enabled.
EOF
}

mirror=""
architecture=""
repository_subdirs=""
packages=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mirror)
      mirror="${2:-}"
      shift 2
      ;;
    --architecture)
      architecture="${2:-}"
      shift 2
      ;;
    --repository-subdirs)
      repository_subdirs="${2:-}"
      shift 2
      ;;
    --packages)
      packages="${2:-}"
      shift 2
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

case "${mirror}" in
  /*) ;;
  *)
    echo "ERROR: --mirror must be an absolute path." >&2
    exit 1
    ;;
esac
case "${architecture}" in
  x86_64|aarch64) ;;
  *)
    echo "ERROR: unsupported APK architecture: ${architecture}" >&2
    exit 1
    ;;
esac
if [ -z "${repository_subdirs}" ]; then
  echo "ERROR: at least one signed repository subdirectory is required." >&2
  exit 1
fi
if [ -z "${packages}" ]; then
  echo "ERROR: at least one locked APK constraint is required." >&2
  exit 1
fi

repositories_file="$(mktemp)"
trap 'rm -f "${repositories_file}"' EXIT HUP INT TERM

set -f
old_ifs="${IFS}"
IFS=' '
# Intentional field splitting; every token is validated before use.
# shellcheck disable=SC2086
set -- ${repository_subdirs}
IFS="${old_ifs}"
set +f

for repository_subdir in "$@"; do
  case "${repository_subdir}" in
    ''|/*|*..*|*[!A-Za-z0-9_./+-]*)
      echo "ERROR: unsafe repository subdirectory: ${repository_subdir}" >&2
      exit 1
      ;;
  esac
  repository="${mirror}/${repository_subdir}"
  if [ ! -f "${repository}/${architecture}/APKINDEX.tar.gz" ]; then
    echo "ERROR: signed APK index is missing:" >&2
    echo "  ${repository}/${architecture}/APKINDEX.tar.gz" >&2
    exit 1
  fi
  printf 'file://%s\n' "${repository}" >> "${repositories_file}"
done

set -f
IFS=' '
# Intentional field splitting; exact constraints are validated below.
# shellcheck disable=SC2086
set -- ${packages}
IFS="${old_ifs}"
set +f

for package_constraint in "$@"; do
  case "${package_constraint}" in
    *=*) ;;
    *)
      echo "ERROR: APK constraint is not exact: ${package_constraint}" >&2
      exit 1
      ;;
  esac
  case "${package_constraint}" in
    *[!A-Za-z0-9_+.=@:~-]*)
      echo "ERROR: unsafe APK constraint: ${package_constraint}" >&2
      exit 1
      ;;
  esac
done

apk add \
  --no-cache \
  --no-network \
  --keys-dir /etc/apk/keys \
  --repositories-file "${repositories_file}" \
  "$@"

rm -f "${repositories_file}"
trap - EXIT HUP INT TERM

for required_command in bash getent jq ldconfig sha256sum tar; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: required VS Code Server command was not installed: ${required_command}" >&2
    exit 1
  fi
done

echo "Installed the locked Wolfi VS Code headless runtime packages."
