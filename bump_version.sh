#!/usr/bin/env bash
#
# bump_version.sh - Accept a new Phoenix version and update the deployment.
#
# Usage: ./bump_version.sh <new_version> [options]
#
# Example:
#   ./bump_version.sh 20.10.0-nonroot
#   ./bump_version.sh 20.10.0-nonroot --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE="${SCRIPT_DIR}/phoenix-update.sh"

usage() {
  cat <<EOF
Usage: ./bump_version.sh <new_version> [options]

Update Phoenix to the specified version.

Options:
  --dry-run    Show planned operations without changing Podman state.
  --no-backup  Skip the pre-update volume archive.
  --help       Show this help.

Arguments:
  new_version        The Phoenix version tag to deploy (e.g. 20.9.0-nonroot).
EOF
}

# Parse arguments
DRY_RUN=0
NO_BACKUP=0
new_version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --no-backup) NO_BACKUP=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    new_version="$1"
    ;;
  esac
  shift
done

if [[ -z "$new_version" ]]; then
  echo "Error: new_version argument required." >&2
  usage >&2
  exit 2
fi

# Export the version and call phoenix-update.sh with the appropriate flags
export PHOENIX_VERSION="$new_version"
if [[ "$DRY_RUN" == "1" ]]; then
  "${UPDATE}" --dry-run
else
  if [[ "$NO_BACKUP" == "1" ]]; then
    "${UPDATE}" --no-backup
  else
    "${UPDATE}"
  fi
fi
