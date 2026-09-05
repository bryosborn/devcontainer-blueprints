#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: configure-core.sh [options]

  --build-enabled true|false
  --python-versions "VERSION ..."
  --java-enabled true|false
  --maven-enabled true|false
  --node-enabled true|false
  --npm-enabled true|false
  --clamav-enabled true|false
  --yq-enabled true|false
EOF
}

build_enabled=false
clang_enabled=false
python_versions=""
java_enabled=false
maven_enabled=false
node_enabled=false
npm_enabled=false
clamav_enabled=false
yq_enabled=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --clang-enabled) clang_enabled="${2:-}"; shift 2 ;;
    --build-enabled) build_enabled="${2:-}"; shift 2 ;;
    --python-versions) python_versions="${2:-}"; shift 2 ;;
    --java-enabled) java_enabled="${2:-}"; shift 2 ;;
    --maven-enabled) maven_enabled="${2:-}"; shift 2 ;;
    --node-enabled) node_enabled="${2:-}"; shift 2 ;;
    --npm-enabled) npm_enabled="${2:-}"; shift 2 ;;
    --clamav-enabled) clamav_enabled="${2:-}"; shift 2 ;;
    --yq-enabled) yq_enabled="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for boolean_value in \
  "${build_enabled}" "${java_enabled}" "${maven_enabled}" \
  "${node_enabled}" "${npm_enabled}" "${clamav_enabled}" "${yq_enabled}"; do
  case "${boolean_value}" in
    true|false) ;;
    *) echo "ERROR: Invalid configure-core boolean: ${boolean_value}" >&2; exit 1 ;;
  esac
done

required_commands="jq"
[ "${build_enabled}" = true ] && required_commands="${required_commands} cc cmake c++ openssl"
[ "${java_enabled}" = true ] && required_commands="${required_commands} java javac"
[ "${maven_enabled}" = true ] && required_commands="${required_commands} mvn"
[ "${node_enabled}" = true ] && required_commands="${required_commands} node corepack"
[ "${npm_enabled}" = true ] && required_commands="${required_commands} npm npx"
[ "${clamav_enabled}" = true ] && required_commands="${required_commands} clamscan"
[ "${yq_enabled}" = true ] && required_commands="${required_commands} yq"

[ "${clang_enabled}" = true ] && required_commands="${required_commands} clang clang++"

default_python=""
for python_version in ${python_versions}; do
  case "${python_version}" in
    ''|*[!0-9.]*) echo "ERROR: Invalid Python selector: ${python_version}" >&2; exit 1 ;;
  esac
  required_commands="${required_commands} python${python_version} pip${python_version}"
  if [ -z "${default_python}" ] || [ "$(printf '%s\n%s\n' "${default_python}" "${python_version}" | sort -V | tail -1)" = "${python_version}" ]; then
    default_python="${python_version}"
  fi
done

for required_command in ${required_commands}; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: Required core toolchain command is missing: ${required_command}" >&2
    exit 1
  fi
done

# The versioned Wolfi Python base packages intentionally do not claim the
# unversioned command. Pick the newest configured runtime as the predictable
# default while retaining both explicit versioned commands.
if [ -n "${default_python}" ]; then
  ln -sfn "$(command -v "python${default_python}")" /usr/local/bin/python3
  ln -sfn "$(command -v "pip${default_python}")" /usr/local/bin/pip3
fi

if [ "${java_enabled}" = true ]; then
  java_binary="$(readlink -f "$(command -v javac)")"
  java_home="$(dirname "$(dirname "${java_binary}")")"
  if [ ! -x "${java_home}/bin/java" ]; then
    echo "ERROR: Could not derive JAVA_HOME from ${java_binary}." >&2
    exit 1
  fi
  ln -sfn "${java_home}" /opt/java
fi

# This writes only Corepack's command shims. Package-manager payload downloads
# remain an explicit, online user action and never occur during image builds.
if [ "${node_enabled}" = true ]; then
  corepack enable
fi

if [ -n "${default_python}" ]; then
  test "$(readlink -f /usr/local/bin/python3)" = \
    "$(readlink -f "$(command -v "python${default_python}")")"
fi
if [ "${java_enabled}" = true ]; then
  test "$(readlink -f /opt/java)" = "${java_home}"
fi
