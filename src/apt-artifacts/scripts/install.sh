#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh [options]

Options:
  --artifact-root DIR     Directory containing debs/, Packages, and Packages.gz.
  --packages-file FILE    Newline-delimited package roots to install.
  -h, --help              Show help.
USAGE
}

ARTIFACT_ROOT="/opt/apt-artifacts"
PACKAGES_FILE="/opt/apt-packages.txt"

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --packages-file)
      PACKAGES_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${ARTIFACT_ROOT}/Packages" || ! -d "${ARTIFACT_ROOT}/debs" ]]; then
  echo "ERROR: invalid APT artifact root:"
  echo "  ${ARTIFACT_ROOT}"
  exit 1
fi

if [[ ! -f "${PACKAGES_FILE}" ]]; then
  echo "ERROR: package list not found:"
  echo "  ${PACKAGES_FILE}"
  exit 1
fi

mapfile -t packages < <(grep -Ev "^\s*(#|$)" "${PACKAGES_FILE}" | sort -u)

echo "Installing packages from local APT artifact repo:"
echo "  ${ARTIFACT_ROOT}"

mkdir -p /tmp/apt-source-backup
if [[ -f /etc/apt/sources.list ]]; then
  mv /etc/apt/sources.list /tmp/apt-source-backup/sources.list
fi
if [[ -d /etc/apt/sources.list.d ]]; then
  mv /etc/apt/sources.list.d /tmp/apt-source-backup/sources.list.d
fi
mkdir -p /etc/apt/sources.list.d
touch /etc/apt/sources.list

echo "deb [trusted=yes] file:${ARTIFACT_ROOT} ./" > /etc/apt/sources.list.d/local-artifacts.list

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"
rm -rf /var/lib/apt/lists/*

rm -f /etc/apt/sources.list
rm -rf /etc/apt/sources.list.d
if [[ -f /tmp/apt-source-backup/sources.list ]]; then
  mv /tmp/apt-source-backup/sources.list /etc/apt/sources.list
fi
if [[ -d /tmp/apt-source-backup/sources.list.d ]]; then
  mv /tmp/apt-source-backup/sources.list.d /etc/apt/sources.list.d
else
  mkdir -p /etc/apt/sources.list.d
fi
rm -rf /tmp/apt-source-backup

echo "APT artifact install complete."
