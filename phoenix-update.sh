#!/usr/bin/env bash
#
# phoenix-update.sh - pull a Phoenix image and recreate the local deployment.
#
# The phoenix_data volume is never removed. A backup is created before the
# update unless --no-backup or --dry-run is specified.
set -euo pipefail

# Pin all podman calls to the dedicated phoenix machine (override with PHOENIX_MACHINE).
export CONTAINER_CONNECTION="${PHOENIX_MACHINE:-phoenix}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${PHOENIX_CONTAINER_NAME:-phoenix}"
PHOENIX_VERSION="${PHOENIX_VERSION:-19.19.1-nonroot}"
IMAGE="${PHOENIX_IMAGE:-docker.io/arizephoenix/phoenix:${PHOENIX_VERSION}}"
NO_BACKUP=0
DRY_RUN="${PHOENIX_DRY_RUN:-0}"

usage() {
  cat <<EOF
Usage: ./phoenix-update.sh [--no-backup] [--dry-run]

Pull and deploy Phoenix ${IMAGE} while preserving the phoenix_data volume.

Options:
  --no-backup  Skip the pre-update volume archive.
  --dry-run    Show the planned operations without changing Podman state.
  --help       Show this help.

Environment:
  PHOENIX_MACHINE       Podman machine to use (default: phoenix)
  PHOENIX_VERSION       Image tag (default: 19.19.1-nonroot)
  PHOENIX_IMAGE         Complete image reference; takes precedence
  PHOENIX_CONTAINER_NAME Container name (default: phoenix)
  PHOENIX_ARCHIVE_DIR   Archive destination, passed to phoenix-archive.sh
EOF
}

for arg in "$@"; do
  case "$arg" in
    --no-backup) NO_BACKUP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] image: ${IMAGE}"
  if [[ "$NO_BACKUP" == "1" ]]; then
    echo "[dry-run] skip archive"
  else
    echo "[dry-run] archive Phoenix data"
  fi
  echo "[dry-run] podman pull ${IMAGE}"
  echo "[dry-run] PHOENIX_IMAGE=${IMAGE} PHOENIX_RECREATE=1 ${SCRIPT_DIR}/phoenix-start.sh"
  echo "[dry-run] verify container ${CONTAINER_NAME} is running"
  exit 0
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "Error: podman is not installed or is not on PATH." >&2
  exit 1
fi
if ! podman info >/dev/null 2>&1; then
  echo "Error: Podman is not reachable. Start the Podman machine first." >&2
  exit 1
fi

# When an authenticated container is recreated, phoenix-start.sh validates the
# initial admin password because the container no longer exists at validation
# time. Preserve missing creation-time settings from the existing container;
# Phoenix ignores the initial password once the database already has an admin.
existing_env="$(podman container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
container_env_value() {
  local name="$1" line
  while IFS= read -r line; do
    if [[ "${line}" == "${name}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<< "${existing_env}"
  return 1
}
for name in PHOENIX_ENABLE_AUTH PHOENIX_SECRET PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD PHOENIX_ENABLE_STRONG_PASSWORD_POLICY; do
  if [[ -z "${!name:-}" ]] && value="$(container_env_value "${name}")"; then
    export "${name}=${value}"
  fi
done

if [[ "$NO_BACKUP" != "1" ]]; then
  echo "Creating a Phoenix data archive before updating..."
  if [[ -n "${PHOENIX_ARCHIVE_DIR:-}" ]]; then
    PHOENIX_ARCHIVE_DIR="${PHOENIX_ARCHIVE_DIR}" "${SCRIPT_DIR}/phoenix-archive.sh"
  else
    "${SCRIPT_DIR}/phoenix-archive.sh"
  fi
fi

echo "Pulling ${IMAGE}..."
podman pull "${IMAGE}"

echo "Recreating ${CONTAINER_NAME} (the phoenix_data volume is preserved)..."
PHOENIX_IMAGE="${IMAGE}" PHOENIX_RECREATE=1 \
  PHOENIX_CONTAINER_NAME="${CONTAINER_NAME}" \
  "${SCRIPT_DIR}/phoenix-start.sh"

status="$(podman container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")"
if [[ "${status}" != "running" ]]; then
  echo "Error: Phoenix container ${CONTAINER_NAME} is not running (status: ${status})." >&2
  exit 1
fi

echo "Phoenix update complete: ${IMAGE}"
echo "Container ${CONTAINER_NAME} is running."
echo "Check logs with: podman logs --tail=100 ${CONTAINER_NAME}"
