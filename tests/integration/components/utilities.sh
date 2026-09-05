#!/usr/bin/env bash
# Appended to a network-disabled profile job. Every network check uses loopback.
set -Eeuo pipefail

utility_enabled() { jq -e --arg key "$1" 'has($key)' <<<"${UTILITIES_JSON}" >/dev/null; }
passed() { printf 'UTILITY_OK %s\n' "$1"; }

while IFS= read -r executable; do
  command -v "${executable}" >/dev/null || { echo "Missing selected utility: ${executable}" >&2; exit 1; }
done < <(jq -r '.[].commands[]' <<<"${UTILITIES_JSON}")

workspace="$(mktemp -d /tmp/toolbox-utilities.XXXXXX)"
background_pids=()
cleanup_utilities() {
  if ((${#background_pids[@]})); then kill "${background_pids[@]}" 2>/dev/null || true; fi
  rm -rf "${workspace}"
}
trap cleanup_utilities EXIT
printf 'toolbox utility fixture\n' >"${workspace}/input.txt"

if utility_enabled curl || utility_enabled wget; then
  python3 -m http.server 18080 --bind 127.0.0.1 --directory "${workspace}" >"${workspace}/http.log" 2>&1 &
  background_pids+=("$!")
  python3 - <<'PY'
import socket, time
for _ in range(50):
    try:
        with socket.create_connection(("127.0.0.1", 18080), timeout=.1):
            break
    except OSError:
        time.sleep(.02)
else:
    raise SystemExit("local HTTP fixture did not start")
PY
fi
if utility_enabled curl; then
  curl --fail --silent --show-error http://127.0.0.1:18080/input.txt >"${workspace}/curl.txt"
  cmp "${workspace}/input.txt" "${workspace}/curl.txt"
  passed curl
fi
if utility_enabled wget; then
  wget --quiet --output-document="${workspace}/wget.txt" http://127.0.0.1:18080/input.txt
  cmp "${workspace}/input.txt" "${workspace}/wget.txt"
  passed wget
fi

if utility_enabled openssh-client; then
  ssh -V
  ssh -G -F /dev/null -o BatchMode=yes fixture.invalid >"${workspace}/ssh-config"
  grep -q '^batchmode yes$' "${workspace}/ssh-config"
  scp -h >"${workspace}/scp-help" 2>&1 || true
  sftp -h >"${workspace}/sftp-help" 2>&1 || true
  grep -qi usage "${workspace}/scp-help"
  grep -qi usage "${workspace}/sftp-help"
  passed openssh-client
fi
if utility_enabled openssh-keygen; then
  ssh-keygen -q -t ed25519 -N '' -f "${workspace}/key"
  ssh-keygen -l -f "${workspace}/key.pub" | grep -q ED25519
  ssh-keygen -y -f "${workspace}/key" | awk '{print $1, $2}' >"${workspace}/derived.pub"
  awk '{print $1, $2}' "${workspace}/key.pub" | cmp - "${workspace}/derived.pub"
  passed openssh-keygen
fi
if utility_enabled openssh-keyscan; then
  ssh-keyscan -h >"${workspace}/keyscan-help" 2>&1 || true
  grep -qi usage "${workspace}/keyscan-help"
  passed openssh-keyscan
fi

if utility_enabled zip; then
  (cd "${workspace}" && zip -q fixture.zip input.txt)
  unzip -l "${workspace}/fixture.zip" | grep -q input.txt
  passed zip
fi
if utility_enabled unzip; then
  unzip -t "${workspace}/fixture.zip" | grep -q 'No errors detected'
  unzip -q "${workspace}/fixture.zip" -d "${workspace}/extracted"
  cmp "${workspace}/input.txt" "${workspace}/extracted/input.txt"
  passed unzip
fi
if utility_enabled less; then
  LESSSECURE=1 less -F -X "${workspace}/input.txt" >"${workspace}/less.txt"
  cmp "${workspace}/input.txt" "${workspace}/less.txt"
  passed less
fi
if utility_enabled procps; then
  test "$(ps -p "$$" -o pid= | tr -d ' ')" = "$$"
  pgrep -f toolbox-utilities >/dev/null
  free --bytes | awk 'NR == 2 {exit !($2 > 0)}'
  passed procps
fi
if utility_enabled findutils; then
  test "$(find "${workspace}" -maxdepth 1 -name input.txt -printf '%f')" = input.txt
  test "$(printf 'a\0b\0' | xargs -0 printf '%s')" = ab
  passed findutils
fi
if utility_enabled rsync; then
  mkdir "${workspace}/rsync-target"
  rsync -a "${workspace}/input.txt" "${workspace}/rsync-target/"
  cmp "${workspace}/input.txt" "${workspace}/rsync-target/input.txt"
  passed rsync
fi
if utility_enabled nano; then
  nano --version | grep -qi 'GNU nano'
  nano --help | grep -qi 'Usage:'
  passed nano
fi

if utility_enabled bind-tools; then
  python3 - <<'PY' &
import socket, struct
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 1053))
while True:
    packet, peer = sock.recvfrom(4096)
    offset = 12
    while packet[offset] != 0:
        offset += packet[offset] + 1
    question = packet[12:offset + 5]
    response = packet[:2] + b"\x81\x80" + b"\x00\x01\x00\x01\x00\x00\x00\x00" + question
    response += b"\xc0\x0c\x00\x01\x00\x01" + struct.pack("!IH", 60, 4) + socket.inet_aton("127.0.0.42")
    sock.sendto(response, peer)
PY
  background_pids+=("$!")
  sleep 0.1
  test "$(dig @127.0.0.1 -p 1053 fixture.test A +short)" = 127.0.0.42
  nslookup -port=1053 fixture.test 127.0.0.1 | grep -q '127.0.0.42'
  passed bind-tools
fi
if utility_enabled iproute2; then
  ip -brief address show lo | grep -q '127.0.0.1'
  ss -ltn | grep -q ':18080'
  passed iproute2
fi
if utility_enabled iputils; then
  ping -c 1 -W 1 127.0.0.1 >/dev/null
  tracepath -n 127.0.0.1 | grep -q '127.0.0.1'
  passed iputils
fi
if utility_enabled netcat-openbsd; then
  nc -l 127.0.0.1 18081 >"${workspace}/nc-received" &
  nc_pid="$!"
  background_pids+=("${nc_pid}")
  sleep 0.1
  printf 'loopback netcat\n' | nc -N 127.0.0.1 18081
  wait "${nc_pid}"
  grep -qx 'loopback netcat' "${workspace}/nc-received"
  passed netcat-openbsd
fi

echo 'Passed every selected utility fixture.'
