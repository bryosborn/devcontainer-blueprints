#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  BASE_TOOLCHAIN_IMAGE \
  BASE_VSCODE_REMOTE_USER

if ! docker image inspect "${BASE_TOOLCHAIN_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Base toolchain image is not available locally:"
  echo "  ${BASE_TOOLCHAIN_IMAGE}"
  echo "Run ./src/base-toolchain/scripts/build-image.sh first."
  exit 1
fi

echo "Testing base toolchain image:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"

docker run --rm \
  --network=none \
  --user root \
  -e "BASE_VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  "${BASE_TOOLCHAIN_IMAGE}" \
  bash -lc '
    set -euo pipefail

    remote_home="$(getent passwd "${BASE_VSCODE_REMOTE_USER}" | cut -d: -f6)"
    code_server="$(find "${remote_home}/.vscode-server/cli/servers" -path "*/server/bin/code-server" -type f -executable | sort | tail -1)"
    extensions_dir="${remote_home}/.vscode-server/extensions"

    test -n "${code_server}"
    test -d "${extensions_dir}"

    java --version
    javac --version
    mvn --version

    node --version
    npm --version
    npx --version

    helm version
    kubectl version --client
    oras version
    yq --version

    "${code_server}" --version
    "${code_server}" \
      --extensions-dir "${extensions_dir}" \
      --user-data-dir /tmp/vscode-server-user-data \
      --list-extensions \
      --show-versions

    docker --version
    docker compose version
    docker-compose version
    docker buildx version

    if command -v dockerd >/dev/null 2>&1; then
      echo "ERROR: dockerd is present; base-toolchain should preserve DOD CLI-only behavior."
      exit 1
    fi
  '

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  python3 --version

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  python3.12 --version

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  python3.13 --version

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  python3.12 -m venv --help >/dev/null

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  python3.13 -m venv --help >/dev/null

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  bash -lc 'set -euo pipefail; python3.12 -m venv /tmp/py312'

docker run --rm \
  --network=none \
  --user root \
  "${BASE_TOOLCHAIN_IMAGE}" \
  bash -lc 'set -euo pipefail; python3.13 -m venv /tmp/py313'

echo "Base toolchain image test completed successfully."
