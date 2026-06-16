#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config/registry.local.env
source "${REPO_ROOT}/config/registry.local.env"

WORKSPACE="${REPO_ROOT}/.tmp/simple-dev-test-workspace"

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}"

cat > "${WORKSPACE}/README.md" <<'EOF'
# Simple Dev Test Workspace

This workspace was generated to test the `simple-dev` Dev Container Template.
EOF

echo "Applying template src/simple-dev to:"
echo "  ${WORKSPACE}"
echo "Using base image:"
echo "  ${DEV_BASE_IMAGE}"

if devcontainer templates apply \
  --workspace-folder "${WORKSPACE}" \
  --template-id "${REPO_ROOT}/src/simple-dev" \
  --template-args "{\"baseImage\":\"${DEV_BASE_IMAGE}\"}"; then
  echo "Template applied with Dev Container CLI."
else
  echo "Dev Container CLI did not apply the local template path."
  echo "Falling back to local file application."
  mkdir -p "${WORKSPACE}/.devcontainer"
  cp "${REPO_ROOT}/src/simple-dev/.devcontainer/Dockerfile" "${WORKSPACE}/.devcontainer/Dockerfile"
  # The template option token must remain literal until this fallback substitution.
  # shellcheck disable=SC2016
  sed 's|${templateOption:baseImage}|'"${DEV_BASE_IMAGE}"'|g' \
    "${REPO_ROOT}/src/simple-dev/.devcontainer/devcontainer.json" \
    > "${WORKSPACE}/.devcontainer/devcontainer.json"
fi

echo "Building dev container for test workspace."

devcontainer build \
  --workspace-folder "${WORKSPACE}"

echo "simple-dev template test completed successfully."
