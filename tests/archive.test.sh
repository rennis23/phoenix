#!/usr/bin/env bash
# Tests phoenix-archive.sh with a mocked Podman CLI.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_SCRIPT="${ROOT}/phoenix-archive.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/archives"

cat > "${TMP}/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "${1:-} ${2:-}" in
  info|stop|start) exit 0 ;;
  "volume exists"|"container exists") exit 0 ;;
  "volume export") printf 'Phoenix test volume\n' ;;
  "container inspect")
    if [[ "$*" == *Config.Image* ]]; then
      printf 'docker.io/arizephoenix/phoenix:latest\n'
    else
      printf 'running\n'
    fi
    ;;
esac
EOF
chmod +x "${TMP}/bin/podman"

: > "${TMP}/podman.log"
PATH="${TMP}/bin:${PATH}" \
MOCK_LOG="${TMP}/podman.log" \
PHOENIX_ARCHIVE_DIR="${TMP}/archives" \
bash "${ARCHIVE_SCRIPT}" >/dev/null

archive_root="$(find "${TMP}/archives" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "${archive_root}" ]] || { echo 'archive directory was not created' >&2; exit 1; }
[[ -s "${archive_root}/phoenix_data.tar" ]] || { echo 'volume archive is empty' >&2; exit 1; }
[[ -s "${archive_root}/phoenix_data.tar.sha256" ]] || { echo 'checksum was not created' >&2; exit 1; }
grep -q '^Image: docker.io/arizephoenix/phoenix:latest$' "${archive_root}/manifest.txt"
grep -q 'volume export phoenix_data' "${TMP}/podman.log"
grep -q '^stop phoenix$' "${TMP}/podman.log"
grep -q '^start phoenix$' "${TMP}/podman.log"

printf 'archive tests: passed\n'
