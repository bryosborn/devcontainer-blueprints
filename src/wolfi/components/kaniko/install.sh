#!/bin/bash
set -Eeuo pipefail
archive=''; expected=''; expected_version=''
while (( $# )); do
  case "$1" in
    --archive) archive="${2:-}"; shift 2 ;;
    --sha256) expected="${2:-}"; shift 2 ;;
    --version) expected_version="${2:-}"; shift 2 ;;
    *) echo "ERROR: Unknown Kaniko installer argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$archive" == /* && -f "$archive" && "$expected" =~ ^[a-f0-9]{64}$ && "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'ERROR: Kaniko requires an absolute archive, locked SHA256, and exact version.' >&2; exit 2;
}
[[ "$(sha256sum "$archive" | cut -d' ' -f1)" == "$expected" ]] || {
  echo 'ERROR: Kaniko archive checksum mismatch.' >&2; exit 1;
}
# The resolver emits exactly three regular files, with no links or directories.
expected_names=$'executor\nssl/certs/ca-certificates.crt\ntini'
[[ "$(tar -tzf "$archive" | sort)" == "$expected_names" ]] || {
  echo 'ERROR: Unexpected Kaniko archive members.' >&2; exit 1;
}
tar -tvzf "$archive" | awk 'substr($1,1,1) != "-" { bad=1 } END { exit bad }' || {
  echo 'ERROR: Kaniko archive contains a non-regular member.' >&2; exit 1;
}
mkdir -p /kaniko/ssl/certs /kaniko/.docker /usr/local/bin
chmod 0755 /kaniko /kaniko/ssl /kaniko/ssl/certs
chmod 0700 /kaniko/.docker
tar -xzof "$archive" --no-same-permissions -C /kaniko
chown -R root:root /kaniko
chmod 0755 /kaniko/executor /kaniko/tini
chmod 0644 /kaniko/ssl/certs/ca-certificates.crt
actual_version="$(/kaniko/executor version | awk 'NF {print $NF}')"
[[ "$actual_version" == "v${expected_version}" ]] || {
  echo "ERROR: Kaniko executable reports $actual_version; expected v${expected_version}." >&2; exit 1;
}
install -o root -g root -m 0755 "$(dirname "$0")/kaniko-build" /usr/local/bin/kaniko-build
