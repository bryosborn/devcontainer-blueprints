#!/usr/bin/env bash
set -Eeuo pipefail
analyzer="$(rustup which rust-analyzer)"
"$analyzer" --version
request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
# Keep stdin open until the server responds; timeout bounds a broken binary.
{ printf 'Content-Length: %s\r\n\r\n%s' "${#request}" "$request"; sleep 5; } \
  | timeout 15 "$analyzer" > "$output" || result=$?
if [[ "${result:-0}" != 0 && "${result:-0}" != 124 ]]; then exit "$result"; fi
grep -Eq '"id"[[:space:]]*:[[:space:]]*1.*"result"|"result".*"id"[[:space:]]*:[[:space:]]*1' "$output"
grep -q '"capabilities"' "$output"
