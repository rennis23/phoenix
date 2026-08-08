#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${PHOENIX_CONTAINER_NAME:-phoenix}"

if podman container exists "${CONTAINER_NAME}"; then
  podman stop "${CONTAINER_NAME}"
else
  echo "Phoenix container ${CONTAINER_NAME} does not exist."
fi
