#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: install-apks.sh --mirror DIR --architecture ARCH \
  --repository-subdirs "DIR ..." --packages "NAME=VERSION ..."

Install exact package roots from frozen, signed Wolfi repositories. Network
repositories and untrusted packages are never enabled.
EOF
}

mirror=""
architecture=""
repository_subdirs=""
packages=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mirror) mirror="${2:-}"; shift 2 ;;
    --architecture) architecture="${2:-}"; shift 2 ;;
    --repository-subdirs) repository_subdirs="${2:-}"; shift 2 ;;
    --packages) packages="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${mirror}" in
  /*) ;;
  *) echo "ERROR: --mirror must be an absolute path." >&2; exit 1 ;;
esac
case "${architecture}" in
  x86_64|aarch64) ;;
  *) echo "ERROR: Unsupported APK architecture: ${architecture}" >&2; exit 1 ;;
esac
if [ "$(apk --print-arch)" != "${architecture}" ]; then
  echo "ERROR: APK mirror architecture ${architecture} does not match $(apk --print-arch)." >&2
  exit 1
fi
if [ -z "${repository_subdirs}" ] || [ -z "${packages}" ]; then
  echo "ERROR: Signed repositories and exact package constraints are required." >&2
  exit 1
fi

repositories_file="$(mktemp)"
trap 'rm -f "${repositories_file}"' EXIT HUP INT TERM

set -f
old_ifs="${IFS}"
IFS=' '
# Deliberate field splitting; every value is validated before it reaches apk.
# shellcheck disable=SC2086
set -- ${repository_subdirs}
IFS="${old_ifs}"
set +f

for repository_subdir in "$@"; do
  case "${repository_subdir}" in
    ''|/*|*..*|*[!A-Za-z0-9_./+-]*)
      echo "ERROR: Unsafe repository subdirectory: ${repository_subdir}" >&2
      exit 1
      ;;
  esac
  repository="${mirror}/${repository_subdir}"
  if [ ! -f "${repository}/${architecture}/APKINDEX.tar.gz" ]; then
    echo "ERROR: Signed APK index is missing: ${repository}/${architecture}/APKINDEX.tar.gz" >&2
    exit 1
  fi
  printf 'file://%s\n' "${repository}" >> "${repositories_file}"
done

set -f
IFS=' '
# Deliberate field splitting; every value is validated before it reaches apk.
# shellcheck disable=SC2086
set -- ${packages}
IFS="${old_ifs}"
set +f

for package_constraint in "$@"; do
  case "${package_constraint}" in
    *=*)
      package_name="${package_constraint%%=*}"
      package_version="${package_constraint#*=}"
      ;;
    *)
      echo "ERROR: Package is not pinned to an exact APK version: ${package_constraint}" >&2
      exit 1
      ;;
  esac
  case "${package_name}" in
    ''|*[!A-Za-z0-9_+.@~-]*)
      echo "ERROR: Unsafe APK package name: ${package_name}" >&2
      exit 1
      ;;
  esac
  case "${package_version}" in
    ''|*=*|*[!A-Za-z0-9_+.~:-]*)
      echo "ERROR: Unsafe APK package version: ${package_version}" >&2
      exit 1
      ;;
  esac
done

# Signature validation uses the trusted keys already present in the
# digest-pinned Wolfi base image. The indexes and packages are supplied only by
# the read-only artifact mount, and --no-network prevents fallback resolution.
apk add \
  --no-cache \
  --no-network \
  --keys-dir /etc/apk/keys \
  --repositories-file "${repositories_file}" \
  "$@"

for package_constraint in "$@"; do
  if ! apk info --installed "${package_constraint}" >/dev/null 2>&1; then
    echo "ERROR: Exact locked package was not installed: ${package_constraint}" >&2
    exit 1
  fi
done

rm -f "${repositories_file}"
trap - EXIT HUP INT TERM
