#!/usr/bin/env bash
#
# phoenix-archive.sh - create a consistent manual archive of Phoenix data.
#
# Phoenix is stopped only when it was running before the archive started, and
# is restored to its previous state after the volume export completes.
#
set -euo pipefail

CONTAINER_NAME="${PHOENIX_CONTAINER_NAME:-phoenix}"
VOLUME_NAME="${PHOENIX_VOLUME_NAME:-phoenix_data}"
ARCHIVE_DIR="${PHOENIX_ARCHIVE_DIR:-${HOME}/Backups/phoenix}"

usage() {
  cat <<EOF
Usage: ./phoenix-archive.sh

Creates a timestamped archive of the ${VOLUME_NAME} Podman volume in:
  ${ARCHIVE_DIR}

Environment: PHOENIX_CONTAINER_NAME, PHOENIX_VOLUME_NAME, PHOENIX_ARCHIVE_DIR
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "${arg}" in
    -h | --help) usage; exit 0 ;;
    *) die "Unknown argument: ${arg}" ;;
  esac
done

command -v podman >/dev/null 2>&1 || die "podman is not installed or is not on PATH."
podman info >/dev/null 2>&1 || die "Podman is not reachable. Start the Podman machine first."
podman volume exists "${VOLUME_NAME}" || die "Podman volume does not exist: ${VOLUME_NAME}"
podman container exists "${CONTAINER_NAME}" || die "Podman container does not exist: ${CONTAINER_NAME}"

was_running=0
status="$(podman container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")"
if [[ "${status}" == "running" ]]; then
  was_running=1
fi

mkdir -p "${ARCHIVE_DIR}"
chmod 700 "${ARCHIVE_DIR}"
timestamp="$(date -u '+%Y-%m-%dT%H%M%SZ')"
archive_root="${ARCHIVE_DIR}/${timestamp}"
archive="${archive_root}/phoenix_data.tar"
checksum="${archive}.sha256"
manifest="${archive_root}/manifest.txt"
tmp_archive="${ARCHIVE_DIR}/.${timestamp}.phoenix_data.tar.tmp"

[[ ! -e "${archive_root}" ]] || die "Archive already exists: ${archive_root}"
mkdir "${archive_root}"
chmod 700 "${archive_root}"

cleanup() {
  local rc=$?
  rm -f "${tmp_archive}"
  if [[ "${was_running}" == "1" ]]; then
    if ! podman container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null | grep -qx running; then
      echo "Restarting Phoenix container ${CONTAINER_NAME}..." >&2
      podman start "${CONTAINER_NAME}" >/dev/null || {
        echo "Error: archive finished, but Phoenix could not be restarted." >&2
        rc=1
      }
    fi
  fi
  if [[ "${rc}" != "0" ]]; then
    rm -rf "${archive_root}"
  fi
  exit "${rc}"
}
trap cleanup EXIT INT TERM

if [[ "${was_running}" == "1" ]]; then
  echo "Stopping Phoenix container ${CONTAINER_NAME}..."
  podman stop "${CONTAINER_NAME}" >/dev/null
fi

echo "Exporting volume ${VOLUME_NAME}..."
podman volume export "${VOLUME_NAME}" > "${tmp_archive}"
mv "${tmp_archive}" "${archive}"
chmod 600 "${archive}"

if command -v shasum >/dev/null 2>&1; then
  digest="$(shasum -a 256 "${archive}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "${archive}" | awk '{print $1}')"
else
  die "Neither shasum nor sha256sum is available."
fi
printf '%s  %s\n' "${digest}" "$(basename "${archive}")" > "${checksum}"
chmod 600 "${checksum}"

image="$(podman container inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || printf 'unknown')"
cat > "${manifest}" <<EOF
Phoenix archive manifest
========================
Created (UTC): ${timestamp}
Container: ${CONTAINER_NAME}
Volume: ${VOLUME_NAME}
Image: ${image}
Archive: $(basename "${archive}")
Checksum: $(basename "${checksum}")
Container was running before archive: $([[ "${was_running}" == "1" ]] && echo yes || echo no)

Restore summary:
  1. Stop/remove the target Phoenix container without removing its volume.
  2. Create an empty target volume with the same name.
  3. Import this archive with: podman volume import <archive> <volume-name>
  4. Recreate Phoenix using the recorded image and existing deployment script.
  5. Restore authentication settings separately from .env or the macOS Keychain.

This archive may contain sensitive traces. Keep it private.
EOF
chmod 600 "${manifest}"

echo "Archive created: ${archive}"
echo "Checksum:        ${checksum}"
if [[ "${was_running}" == "1" ]]; then
  echo "Restarting Phoenix container ${CONTAINER_NAME}..."
  podman start "${CONTAINER_NAME}" >/dev/null
  echo "Phoenix container restarted."
else
  echo "Phoenix was stopped before archiving and remains stopped."
fi

trap - EXIT INT TERM
rm -f "${tmp_archive}"
exit 0
