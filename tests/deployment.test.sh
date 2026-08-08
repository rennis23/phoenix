#!/usr/bin/env bash
#
# Deployment tests for phoenix-start.sh and phoenix-secrets.sh.
#
# Uses a mocked podman and mocked macOS `security` CLI on PATH so no containers,
# volumes, images, or Keychain items are touched. Run from anywhere:
#
#   ./tests/deployment.test.sh
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="${ROOT}/phoenix-start.sh"
SECRETS="${ROOT}/phoenix-secrets.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
CURRENT=""

begin() { CURRENT="$1"; }
ok() { PASS=$((PASS + 1)); echo "ok   - ${CURRENT}"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - ${CURRENT}: $1"; }

# --- mocks ---------------------------------------------------------------------

MOCK_LOG="${TMP}/podman.log"
MOCK_SECRET_DIR="${TMP}/secrets"
mkdir -p "${TMP}/bin" "${MOCK_SECRET_DIR}"

cat > "${TMP}/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG}"
case "${1:-}" in
  info) exit 0 ;;
  container)
    case "${2:-}" in
      exists)
        if [[ "${MOCK_CONTAINER_EXISTS:-0}" == "1" ]]; then exit 0; else exit 1; fi
        ;;
      inspect)
        if [[ "${4:-}" == *Config.Env* ]]; then
          printf '%s\n' "${MOCK_CONTAINER_ENV:-}"
        else
          printf '%s\n' "${MOCK_CONTAINER_STATUS:-running}"
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;
  volume)
    case "${2:-}" in
      exists)
        if [[ "${MOCK_VOLUME_EXISTS:-0}" == "1" ]]; then exit 0; else exit 1; fi
        ;;
    esac
    exit 0
    ;;
  pull) exit 0 ;;
  run | start | rm | stop) exit 0 ;;
  port) printf '127.0.0.1:6006 -> 6006\n127.0.0.1:4317 -> 4317\n' ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/podman"

# Mock macOS `security`. Stored values live in MOCK_SECRET_DIR/<NAME>.
cat > "${TMP}/bin/security" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift
label=""
value=""
while (($#)); do
  a="$1"; shift
  case "$a" in
    -a | -s) shift ;;
    -w)
      if [[ "$cmd" == "add-generic-password" ]]; then
        value="${1:-}"
        shift
      fi
      ;;
    *) label="$a" ;;
  esac
done
file="${MOCK_SECRET_DIR}/${label}"
case "$cmd" in
  add-generic-password)
    printf '%s' "$value" > "$file"
    exit 0
    ;;
  find-generic-password)
    if [[ -f "$file" ]]; then
      printf '%s' "$(cat "$file")"
      exit 0
    fi
    echo "security: item not found" >&2
    exit 44
    ;;
  delete-generic-password)
    rm -f "$file"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/security"

# --- helpers -------------------------------------------------------------------

# run_start <env-file> [KEY=VALUE ...]
#   Runs the start script with mocked podman/security. Mock state and
#   PHOENIX_* overrides can be passed as additional KEY=VALUE arguments, which
#   take precedence over the defaults. Sets OUT and ERR globals; returns the
#   script's exit code.
run_start() {
  local envfile="$1"
  shift
  local -a run_env=(
    PATH="${TMP}/bin:${PATH}"
    MOCK_LOG="${MOCK_LOG}"
    MOCK_SECRET_DIR="${MOCK_SECRET_DIR}"
    MOCK_CONTAINER_EXISTS=0
    MOCK_VOLUME_EXISTS=0
    MOCK_CONTAINER_STATUS=stopped
    MOCK_CONTAINER_ENV=""
    PHOENIX_ENV_FILE="${envfile}"
  )
  run_env+=("$@")
  env "${run_env[@]}" bash "${START}" >"${TMP}/out.log" 2>"${TMP}/err.log"
  local rc=$?
  OUT="$(cat "${TMP}/out.log")"
  ERR="$(cat "${TMP}/err.log")"
  return "${rc}"
}

out_has() { grep -qF -- "$1" "${TMP}/out.log" || bad "stdout missing: $1"; }
out_lacks() { ! grep -qF -- "$1" "${TMP}/out.log" || bad "stdout unexpectedly contains: $1"; }
err_has() { grep -qF -- "$1" "${TMP}/err.log" || bad "stderr missing: $1"; }
err_lacks() { ! grep -qF -- "$1" "${TMP}/err.log" || bad "stderr unexpectedly contains: $1"; }
log_has() { grep -qF -- "$1" "${MOCK_LOG}" || bad "podman log missing: $1"; }
log_lacks() { ! grep -qF -- "$1" "${MOCK_LOG}" || bad "podman log unexpectedly contains: $1"; }

: > "${MOCK_LOG}"

# --- fixtures ------------------------------------------------------------------

write_env() {
  local file="$1"
  shift
  printf '%s\n' "$@" > "${file}"
  chmod 600 "${file}"
}

SECRET="$(openssl rand -hex 32)"        # 64 chars, digits + lowercase
SECRET_SHORT="$(printf 'a%.0s' {1..10})"
ADMIN_PW="Ab3!x$(openssl rand -hex 8)"
ADMIN_PW_SHORT="Aa1!x"
API_KEY="phx_test_$(openssl rand -hex 12)"

# --- tests ---------------------------------------------------------------------

begin "creates an authenticated container from .env and propagates auth env"
ENV_FILE="${TMP}/t1.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET=\"${SECRET}\"" \
  "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=\"${ADMIN_PW}\"" \
  "PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true" \
  "PHOENIX_API_KEY=${API_KEY}"
if run_start "${ENV_FILE}"; then
  log_has "run --detach --name phoenix"
  log_has "--env PHOENIX_ENABLE_AUTH=true"
  log_has "--env PHOENIX_SECRET=${SECRET}"
  log_has "--env PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}"
  log_has "--env PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true"
  ok
else
  bad "start failed: ${ERR}"
fi

begin "secrets are never printed to stdout/stderr"
if [[ "${OUT}" == *"${SECRET}"* || "${ERR}" == *"${SECRET}"* || "${OUT}" == *"${ADMIN_PW}"* || "${ERR}" == *"${ADMIN_PW}"* ]]; then
  bad "secret leaked"
else
  ok
fi

begin "localhost-only port bindings"
log_has "--publish 127.0.0.1:6006:6006"
log_has "--publish 127.0.0.1:4317:4317"
if grep -q -- "--publish [^1]" "${MOCK_LOG}"; then bad "non-localhost publish found"; else ok; fi

begin "missing PHOENIX_SECRET with auth enabled fails"
ENV_FILE="${TMP}/t3.env"
write_env "${ENV_FILE}" "PHOENIX_ENABLE_AUTH=true"
if run_start "${ENV_FILE}"; then bad "expected failure"; else
  err_has "requires PHOENIX_SECRET"
  ok
fi

begin "short PHOENIX_SECRET fails validation"
ENV_FILE="${TMP}/t4.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET=${SECRET_SHORT}" \
  "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}"
if run_start "${ENV_FILE}"; then bad "expected failure"; else
  err_has "at least 32 characters"
  ok
fi

begin "missing initial admin password fails on fresh container"
ENV_FILE="${TMP}/t5.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET=${SECRET}"
if run_start "${ENV_FILE}"; then bad "expected failure"; else
  err_has "requires PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD"
  ok
fi

begin "weak initial admin password fails with strong policy"
ENV_FILE="${TMP}/t6.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET=${SECRET}" \
  "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW_SHORT}" \
  "PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true"
if run_start "${ENV_FILE}"; then bad "expected failure"; else
  err_has "at least 12 characters"
  ok
fi

begin "missing PHOENIX_API_KEY warns but does not block"
ENV_FILE="${TMP}/t7.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET=${SECRET}" \
  "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}"
if run_start "${ENV_FILE}"; then
  err_has "PHOENIX_API_KEY is not set"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "existing stopped container is started, not recreated"
: > "${MOCK_LOG}"
ENV_FILE="${TMP}/t8.env"
write_env "${ENV_FILE}" "PHOENIX_ENABLE_AUTH=true" "PHOENIX_SECRET=${SECRET}" \
  "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}"
if run_start "${ENV_FILE}" MOCK_CONTAINER_EXISTS=1 MOCK_CONTAINER_STATUS=stopped; then
  log_has "start phoenix"
  log_lacks "run --detach"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "running container reports ports without recreating"
: > "${MOCK_LOG}"
if run_start "${ENV_FILE}" MOCK_CONTAINER_EXISTS=1 MOCK_CONTAINER_STATUS=running; then
  log_has "port phoenix"
  log_lacks "run --detach"
  log_lacks "start phoenix"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "config drift (container without auth, .env with auth) warns, no recreate"
: > "${MOCK_LOG}"
if run_start "${ENV_FILE}" MOCK_CONTAINER_EXISTS=1 MOCK_CONTAINER_STATUS=running \
  MOCK_CONTAINER_ENV="PHOENIX_WORKING_DIR=/mnt/data"; then
  err_has "created without authentication"
  log_lacks "run --detach"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "secret drift (container auth with different secret) warns"
: > "${MOCK_LOG}"
OLD_SECRET="$(openssl rand -hex 32)"
if run_start "${ENV_FILE}" MOCK_CONTAINER_EXISTS=1 MOCK_CONTAINER_STATUS=running \
  MOCK_CONTAINER_ENV=$'PHOENIX_ENABLE_AUTH=true\nPHOENIX_SECRET='"${OLD_SECRET}"; then
  err_has "PHOENIX_SECRET differs"
  err_lacks "created without authentication"
  log_lacks "run --detach"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "matching auth container with same secret stays quiet"
: > "${MOCK_LOG}"
if run_start "${ENV_FILE}" MOCK_CONTAINER_EXISTS=1 MOCK_CONTAINER_STATUS=running \
  MOCK_CONTAINER_ENV=$'PHOENIX_ENABLE_AUTH=true\nPHOENIX_SECRET='"${SECRET}"; then
  err_lacks "PHOENIX_SECRET differs"
  err_lacks "created without authentication"
  log_lacks "run --detach"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "PHOENIX_RECREATE=1 recreates the container"
: > "${MOCK_LOG}"
if run_start "${ENV_FILE}" PHOENIX_RECREATE=1 MOCK_CONTAINER_EXISTS=1 MOCK_CONTAINER_STATUS=stopped; then
  log_has "rm -f phoenix"
  log_has "run --detach"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "keychain mode resolves secrets and passes them to podman"
: > "${MOCK_LOG}"
printf '%s' "${SECRET}" > "${MOCK_SECRET_DIR}/PHOENIX_SECRET"
printf '%s' "${ADMIN_PW}" > "${MOCK_SECRET_DIR}/PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD"
printf '%s' "${API_KEY}" > "${MOCK_SECRET_DIR}/PHOENIX_API_KEY"
ENV_FILE="${TMP}/t12.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET_SOURCE=keychain" \
  "PHOENIX_KEYCHAIN_SERVICE=phoenix-local" \
  "PHOENIX_KEYCHAIN_ACCOUNT=testuser" \
  "PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true"
if run_start "${ENV_FILE}"; then
  log_has "--env PHOENIX_SECRET=${SECRET}"
  log_has "--env PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}"
  err_lacks "PHOENIX_API_KEY is not set"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "keychain mode missing API key warns"
: > "${MOCK_LOG}"
rm -f "${MOCK_SECRET_DIR}/PHOENIX_API_KEY"
if run_start "${ENV_FILE}"; then
  err_has "PHOENIX_API_KEY is not set"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "dry-run prints masked commands and does not leak secrets"
: > "${MOCK_LOG}"
ENV_FILE="${TMP}/t14.env"
write_env "${ENV_FILE}" \
  "PHOENIX_ENABLE_AUTH=true" \
  "PHOENIX_SECRET=${SECRET}" \
  "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}" \
  "PHOENIX_API_KEY=${API_KEY}"
if run_start "${ENV_FILE}" PHOENIX_DRY_RUN=1; then
  err_has "[dry-run] podman run"
  err_has "PHOENIX_SECRET=****"
  err_lacks "${SECRET}"
  err_lacks "${ADMIN_PW}"
  err_lacks "${API_KEY}"
  log_lacks "run --detach"
  ok
else
  bad "expected success: ${ERR}"
fi

begin "no .env keeps anonymous behavior (no auth env passed)"
: > "${MOCK_LOG}"
if run_start "/nonexistent/.env"; then
  log_lacks "PHOENIX_ENABLE_AUTH"
  log_lacks "PHOENIX_SECRET="
  ok
else
  bad "expected success: ${ERR}"
fi

begin "keychain:set/get/check/delete round-trip"
printf '%s' "roundtrip-value" | \
  env PATH="${TMP}/bin:${PATH}" MOCK_SECRET_DIR="${MOCK_SECRET_DIR}" \
    bash "${SECRETS}" keychain:set PHOENIX_API_KEY >/dev/null 2>&1
got="$(env PATH="${TMP}/bin:${PATH}" MOCK_SECRET_DIR="${MOCK_SECRET_DIR}" \
  bash "${SECRETS}" keychain:get PHOENIX_API_KEY 2>/dev/null)"
if [[ "${got}" == "roundtrip-value" ]]; then ok; else bad "get returned '${got}'"; fi
if env PATH="${TMP}/bin:${PATH}" MOCK_SECRET_DIR="${MOCK_SECRET_DIR}" \
  bash "${SECRETS}" keychain:check PHOENIX_API_KEY >/dev/null 2>&1; then ok; else bad "check failed"; fi
env PATH="${TMP}/bin:${PATH}" MOCK_SECRET_DIR="${MOCK_SECRET_DIR}" \
  bash "${SECRETS}" keychain:delete PHOENIX_API_KEY >/dev/null 2>&1
if [[ -f "${MOCK_SECRET_DIR}/PHOENIX_API_KEY" ]]; then bad "delete did not remove item"; else ok; fi

# --- summary -------------------------------------------------------------------

echo
echo "deployment tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
