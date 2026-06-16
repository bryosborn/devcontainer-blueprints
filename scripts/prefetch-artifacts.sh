#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APT_PACKAGE_FILE="${REPO_ROOT}/config/apt-packages.txt"
APT_DEB_DIR="${REPO_ROOT}/artifacts/apt/debs"
CHECKSUM_DIR="${REPO_ROOT}/artifacts/checksums"

mkdir -p "${APT_DEB_DIR}" "${CHECKSUM_DIR}"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: This minimal prefetch script requires apt-get on the host."
  echo "Run it on a Debian/Ubuntu host, or replace it later with a containerized prefetcher."
  exit 1
fi

if ! command -v apt-rdepends >/dev/null 2>&1; then
  echo "WARNING: apt-rdepends is not installed."
  echo "Only explicitly listed packages will be downloaded."
  echo "For better dependency discovery, install apt-rdepends on the host."
fi

echo "Updating host APT package metadata."
sudo apt-get update

echo "Prefetching APT packages into:"
echo "  ${APT_DEB_DIR}"

cd "${APT_DEB_DIR}"

while IFS= read -r package; do
  package="$(echo "${package}" | sed 's/#.*//' | xargs)"
  if [ -z "${package}" ]; then
    continue
  fi

  echo "Resolving package: ${package}"

  if command -v apt-rdepends >/dev/null 2>&1; then
    apt-rdepends "${package}" \
      | grep -v "^ " \
      | grep -v "^PreDepends:" \
      | grep -v "^Depends:" \
      | grep -v "^Conflicts:" \
      | grep -v "^Breaks:" \
      | grep -v "^Replaces:" \
      | grep -v "^Suggests:" \
      | grep -v "^Recommends:" \
      | sort -u \
      | while read -r dep; do
          if [ -n "${dep}" ]; then
            echo "Downloading ${dep}"
            apt-get download "${dep}" || true
          fi
        done
  else
    echo "Downloading explicit package only: ${package}"
    apt-get download "${package}" || true
  fi
done < "${APT_PACKAGE_FILE}"

echo "Generating SHA256 manifest."

find "${APT_DEB_DIR}" -type f -name "*.deb" -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "${CHECKSUM_DIR}/apt-debs.sha256"

echo "Downloaded artifacts:"
find "${APT_DEB_DIR}" -type f -name "*.deb" | sort

echo "Wrote checksum manifest:"
echo "  ${CHECKSUM_DIR}/apt-debs.sha256"
