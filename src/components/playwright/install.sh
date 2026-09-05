#!/bin/sh
set -eu

artifact_root=""
archive_relative=""
archive_sha256=""
version=""
platform=""
destination=/opt/playwright
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-root) artifact_root="${2:-}"; shift 2 ;;
    --archive-relative) archive_relative="${2:-}"; shift 2 ;;
    --archive-sha256) archive_sha256="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --destination) destination="${2:-}"; shift 2 ;;
    *) echo "ERROR: Unknown Playwright installer argument: $1" >&2; exit 2 ;;
  esac
done
case "${artifact_root}" in /*) ;; *) echo 'ERROR: Absolute artifact root required.' >&2; exit 1 ;; esac
case "${destination}" in /*) ;; *) echo 'ERROR: Absolute destination required.' >&2; exit 1 ;; esac
case "${archive_relative}" in ''|/*|*..*) echo 'ERROR: Unsafe Playwright archive path.' >&2; exit 1 ;; esac
case "${archive_sha256}" in ''|*[!a-f0-9]*) echo 'ERROR: Invalid Playwright SHA256.' >&2; exit 1 ;; esac
[ "${#archive_sha256}" -eq 64 ] || { echo 'ERROR: Invalid Playwright SHA256 length.' >&2; exit 1; }
case "${platform}" in linux/amd64|linux/arm64) ;; *) echo 'ERROR: Invalid Playwright platform.' >&2; exit 1 ;; esac
archive="${artifact_root}/${archive_relative}"
[ -f "${archive}" ] || { echo 'ERROR: Missing frozen Playwright archive.' >&2; exit 1; }
actual="$(sha256sum "${archive}" | cut -d' ' -f1)"
[ "${actual}" = "${archive_sha256}" ] || { echo 'ERROR: Playwright archive SHA256 mismatch.' >&2; exit 1; }

# The resolver's normalized archive contains only files and directories. Reject
# links, special files, elevated modes and traversal before privileged extraction.
tar -tvzf "${archive}" | awk '
  $1 !~ /^[-d][rwx-]+$/ || length($1) != 10 { bad = 1 }
  substr($1, 9, 1) == "w" { bad = 1 }
  END { exit bad }
' || { echo 'ERROR: Unsafe Playwright archive member type/mode.' >&2; exit 1; }
tar -tzf "${archive}" | awk '
  !/^(manifest.json|browsers(\/[^[:space:]]*)?)$/ { bad = 1 }
  { n = split($0, p, "/"); for (i = 1; i <= n; i++) if (p[i] == "..") bad = 1 }
  END { exit bad }
' || { echo 'ERROR: Unsafe Playwright archive member path.' >&2; exit 1; }

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT HUP INT TERM
tar -xzof "${archive}" -C "${temporary}"
node "$(dirname "$0")/validate-install.cjs" "${temporary}" "${version}" "${platform}"
mkdir -p "${destination}"
if [ -e "${destination}/manifest.json" ] || [ -e "${destination}/browsers" ]; then
  echo 'ERROR: Playwright installation destination is already populated.' >&2
  exit 1
fi
cp -a "${temporary}/." "${destination}/"
chown -R root:root "${destination}"
chmod -R a+rX,go-w "${destination}"
