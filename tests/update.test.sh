#!/usr/bin/env bash
# Tests for phoenix-update.sh using a mocked Podman command.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="${ROOT}/phoenix-update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
LOG="${TMP}/podman.log"
mkdir -p "${TMP}/bin"
: >"${LOG}"

cat >"${TMP}/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "${1:-}" in
  info) exit 0 ;;
  pull) [[ "${MOCK_PULL_FAIL:-0}" == 1 ]] && exit 1 || exit 0 ;;
  container)
    case "${2:-}" in
      exists) exit 0 ;;
      inspect)
        if [[ "${4:-}" == *Config.Env* ]]; then
          printf '%s\n' "${MOCK_CONTAINER_ENV:-}"
        elif [[ "${4:-}" == *Config.Image* ]]; then
          printf '%s\n' "${PHOENIX_IMAGE:-docker.io/arizephoenix/phoenix:${PHOENIX_VERSION:-20.8.0-nonroot}}"
        else
          printf '%s\n' running
        fi
        exit 0
        ;;
    esac
    ;;
  volume) exit 0 ;;
  rm|run|start|stop|port) exit 0 ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/podman"

run_update() {
  : >"${LOG}"
  PATH="${TMP}/bin:${PATH}" MOCK_LOG="${LOG}" \
    PHOENIX_ENV_FILE="${TMP}/empty.env" "$@" "${UPDATE}" --no-backup \
    >"${TMP}/out" 2>"${TMP}/err"
}

check() {
  local name="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file"; then
    PASS=$((PASS + 1))
    printf 'ok   - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL - %s\n' "$name"
    cat "$file" >&2
  fi
}

run_update env
check "uses the non-root default image" "pull docker.io/arizephoenix/phoenix:20.8.0-nonroot" "$LOG"
check "recreates through the start script" "run --detach --name phoenix" "$LOG"
check "verifies the deployed image" "container inspect --format {{.Config.Image}} phoenix" "$LOG"

run_update env PHOENIX_VERSION=20.2.0-nonroot
check "supports version override" "pull docker.io/arizephoenix/phoenix:20.2.0-nonroot" "$LOG"

run_update env PHOENIX_IMAGE=example.test/phoenix:custom
check "supports complete image override" "pull example.test/phoenix:custom" "$LOG"

EXISTING_SECRET="existing_secret_123456789012345678901234567890"
EXISTING_ADMIN="existing-admin-password"
run_update env MOCK_CONTAINER_ENV=$'PHOENIX_ENABLE_AUTH=true\nPHOENIX_SECRET='"${EXISTING_SECRET}"$'\nPHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD='"${EXISTING_ADMIN}"
check "preserves existing admin bootstrap settings" "--env PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${EXISTING_ADMIN}" "$LOG"

: >"${LOG}"
if PATH="${TMP}/bin:${PATH}" MOCK_LOG="${LOG}" "${UPDATE}" --dry-run >"${TMP}/dry" 2>"${TMP}/err"; then
  check "dry-run prints the pull" "[dry-run] podman pull docker.io/arizephoenix/phoenix:20.8.0-nonroot" "${TMP}/dry"
  if [[ ! -s "${LOG}" ]]; then
    PASS=$((PASS + 1))
    echo "ok   - dry-run does not call Podman"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - dry-run called Podman"
  fi
else
  FAIL=$((FAIL + 1))
  echo "FAIL - dry-run failed"
fi

if PATH="${TMP}/bin:${PATH}" MOCK_LOG="${LOG}" MOCK_PULL_FAIL=1 \
  PHOENIX_ENV_FILE="${TMP}/empty.env" "${UPDATE}" --no-backup >"${TMP}/out" 2>"${TMP}/err"; then
  FAIL=$((FAIL + 1))
  echo "FAIL - pull failure did not stop update"
else
  if ! grep -qF 'run --detach' "$LOG"; then
    PASS=$((PASS + 1))
    echo "ok   - pull failure stops before recreation"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - recreation ran after pull failure"
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
