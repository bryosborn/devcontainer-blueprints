#!/usr/bin/env bash
# Appended to the selected image's network-disabled runtime test.
set -Eeuo pipefail
utility_enabled() { jq -e --arg key "$1" 'has($key)' <<<"${UTILITIES_JSON}" >/dev/null; }
while IFS= read -r executable; do
  command -v "$executable" >/dev/null || { echo "Missing selected utility: $executable" >&2; exit 1; }
done < <(jq -r '.[].commands[]' <<<"${UTILITIES_JSON}")
workspace="$(mktemp -d /tmp/wolfi-utilities.XXXXXX)"
trap 'rm -rf "$workspace"' EXIT
printf 'wolfi utility fixture\n' >"$workspace/input.txt"
if utility_enabled curl; then
  curl --fail --silent --show-error "file://$workspace/input.txt" >"$workspace/curl.txt"
  cmp "$workspace/input.txt" "$workspace/curl.txt"
fi
if utility_enabled openssh-client; then
  ssh -V
  ssh -G -F /dev/null -o BatchMode=yes fixture.invalid >"$workspace/ssh-config"
  grep -q '^batchmode yes$' "$workspace/ssh-config"
fi
if utility_enabled openssh-keygen; then
  ssh-keygen -q -t ed25519 -N '' -f "$workspace/key"
  ssh-keygen -l -f "$workspace/key.pub"
fi
if utility_enabled zip; then (cd "$workspace" && zip -q fixture.zip input.txt); fi
if utility_enabled unzip; then
  unzip -v
  if utility_enabled zip; then
    unzip -q "$workspace/fixture.zip" -d "$workspace/extracted"
    cmp "$workspace/input.txt" "$workspace/extracted/input.txt"
  fi
fi
if utility_enabled less; then less --version; fi
if utility_enabled procps; then
  ps --version
  test "$(ps -p "$$" -o pid= | tr -d ' ')" = "$$"
  free --version
fi
if utility_enabled findutils; then
  find . --version
  test "$(find "$workspace" -maxdepth 1 -name input.txt -printf '%f')" = input.txt
  test "$(printf 'a\0b\0' | xargs -0 printf '%s')" = ab
fi
if utility_enabled rsync; then
  rsync -a "$workspace/input.txt" "$workspace/rsync.txt"
  cmp "$workspace/input.txt" "$workspace/rsync.txt"
fi
if utility_enabled wget; then wget --version; fi
if utility_enabled nano; then nano --version; fi
if utility_enabled bind-tools; then dig -v; fi
if utility_enabled iproute2; then ip -Version; ss --version; fi
if utility_enabled iputils; then ping -V; tracepath -V; fi
if utility_enabled netcat-openbsd; then nc -h >"$workspace/nc-help" 2>&1; fi
echo 'Passed every selected utility fixture.'
