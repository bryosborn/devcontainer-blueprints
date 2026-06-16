#!/usr/bin/env bash
set -euo pipefail

REGISTRY_CONTAINER_NAME="${REGISTRY_CONTAINER_NAME:-registry-5001}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"

if docker ps --format '{{.Names}}' | grep -qx "${REGISTRY_CONTAINER_NAME}"; then
  echo "Local registry '${REGISTRY_CONTAINER_NAME}' is already running."
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${REGISTRY_CONTAINER_NAME}"; then
  echo "Starting existing local registry '${REGISTRY_CONTAINER_NAME}'."
  docker start "${REGISTRY_CONTAINER_NAME}"
  exit 0
fi

echo "Creating local registry '${REGISTRY_CONTAINER_NAME}' on port ${REGISTRY_PORT}."

docker run -d \
  --restart=always \
  -p "${REGISTRY_PORT}:5000" \
  --name "${REGISTRY_CONTAINER_NAME}" \
  registry:2

echo "Local registry is available at localhost:${REGISTRY_PORT}."
