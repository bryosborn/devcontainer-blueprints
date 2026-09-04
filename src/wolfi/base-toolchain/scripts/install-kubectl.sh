#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: install-kubectl.sh --artifact-root DIR --artifact-relative FILE \
  --hash-algorithm sha256|sha512 --hash HASH --version VERSION
EOF
}

artifact_root=""
artifact_relative=""
hash_algorithm=""
expected_hash=""
expected_version=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-root) artifact_root="${2:-}"; shift 2 ;;
    --artifact-relative|--archive-relative) artifact_relative="${2:-}"; shift 2 ;;
    --hash-algorithm) hash_algorithm="${2:-}"; shift 2 ;;
    --hash) expected_hash="${2:-}"; shift 2 ;;
    --version) expected_version="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${artifact_root}" in /*) ;; *) echo "ERROR: --artifact-root must be absolute." >&2; exit 1 ;; esac
case "${artifact_relative}" in ''|/*|*..*) echo "ERROR: Unsafe kubectl artifact path." >&2; exit 1 ;; esac
case "${expected_version}" in v*) expected_version="${expected_version#v}" ;; esac
case "${expected_version}" in
  ''|*[!0-9.]*|.*|*.) echo "ERROR: Invalid kubectl version: ${expected_version}" >&2; exit 1 ;;
esac
case "${hash_algorithm}" in
  sha256) hash_command=sha256sum; hash_length=64 ;;
  sha512) hash_command=sha512sum; hash_length=128 ;;
  *) echo "ERROR: Unsupported kubectl hash algorithm: ${hash_algorithm}" >&2; exit 1 ;;
esac
case "${expected_hash}" in *[!a-f0-9]*) echo "ERROR: Invalid kubectl hash." >&2; exit 1 ;; esac
if [ "${#expected_hash}" -ne "${hash_length}" ]; then
  echo "ERROR: Invalid ${hash_algorithm} kubectl hash length." >&2
  exit 1
fi

artifact="${artifact_root}/${artifact_relative}"
if [ ! -f "${artifact}" ]; then
  echo "ERROR: Frozen kubectl artifact is missing: ${artifact}" >&2
  exit 1
fi
actual_hash="$(${hash_command} "${artifact}" | cut -d' ' -f1)"
if [ "${actual_hash}" != "${expected_hash}" ]; then
  echo "ERROR: kubectl artifact checksum does not match the lock." >&2
  exit 1
fi

# The Wolfi resolver locks Kubernetes' upstream-published standalone binary.
# Refuse archive input so a tar member can never redirect this privileged
# installation through a symlink or special file.
case "${artifact_relative}" in
  *.tar|*.tar.*|*.tgz)
    echo "ERROR: kubectl must be supplied as the locked standalone binary." >&2
    exit 1
    ;;
esac
install -o root -g root -m 0755 "${artifact}" /usr/local/bin/kubectl

reported_version="$(kubectl version --client --output=json | jq -r '.clientVersion.gitVersion')"
if [ "${reported_version}" != "v${expected_version}" ]; then
  echo "ERROR: kubectl reported ${reported_version}; expected v${expected_version}." >&2
  exit 1
fi
