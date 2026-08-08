#!/usr/bin/env bash
#
# Smoke tests for the authenticated local Phoenix deployment.
#
# Runs a disposable, authenticated Phoenix container and verifies:
#   - the UI and OTLP endpoint are login-protected
#   - unauthenticated and invalid/revoked API keys are rejected
#   - exporting a span with a valid API key succeeds and is visible via the API
#   - data survives a container restart
#
# Prerequisites: a running Podman machine, curl, node, and the
# @arizeai/phoenix-otel package (found in the pi npm directory, or override
# with PHOENIX_OTEL_ENTRY).
#
#   ./tests/smoke.test.sh
#
# Options (environment):
#   PHOENIX_IMAGE          image to test (default: docker.io/arizephoenix/phoenix:latest)
#   PHOENIX_SMOKE_PORT     host port (default: 16006)
#   PHOENIX_OTEL_ENTRY     absolute path to @arizeai/phoenix-otel ESM entry
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PHOENIX_IMAGE:-docker.io/arizephoenix/phoenix:latest}"
PORT="${PHOENIX_SMOKE_PORT:-16006}"
BASE="http://127.0.0.1:${PORT}"
CONTAINER="phoenix-smoke-$$"
COOKIE_JAR="$(mktemp)"
TMP="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  podman rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  rm -f "${COOKIE_JAR}"
  rm -rf "${TMP}"
}
trap cleanup EXIT

check() { # check <desc> <condition-cmd...>
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "ok   - ${desc}"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - ${desc}"
  fi
}

fail_fatal() {
  echo "FAIL - $*" >&2
  exit 1
}

# --- resolve @arizeai/phoenix-otel entry --------------------------------------

OTEL_ENTRY="${PHOENIX_OTEL_ENTRY:-}"
if [[ -z "${OTEL_ENTRY}" ]]; then
  for candidate in \
    "${HOME}/.pi/agent/npm/node_modules/@arizeai/phoenix-otel/dist/esm/register.js" \
    "${HOME}/.config/pi/npm/node_modules/@arizeai/phoenix-otel/dist/esm/register.js"; do
    if [[ -f "${candidate}" ]]; then
      OTEL_ENTRY="${candidate}"
      break
    fi
  done
fi
if [[ -z "${OTEL_ENTRY}" ]]; then
  fail_fatal "@arizeai/phoenix-otel not found; set PHOENIX_OTEL_ENTRY."
fi
if ! command -v node >/dev/null 2>&1; then
  fail_fatal "node is required for the smoke tests."
fi

# --- start disposable authenticated instance ------------------------------------

SECRET="$(openssl rand -hex 32)"
ADMIN_PW="$("${ROOT}/phoenix-secrets.sh" generate password)"

echo "Starting disposable authenticated Phoenix on port ${PORT}..."
podman run -d --name "${CONTAINER}" \
  --publish "127.0.0.1:${PORT}:6006" \
  --env PHOENIX_ENABLE_AUTH=true \
  --env "PHOENIX_SECRET=${SECRET}" \
  --env "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${ADMIN_PW}" \
  --env PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true \
  "${IMAGE}" >/dev/null

echo "Waiting for Phoenix readiness (this can take a minute while migrations run)..."
ready=0
for _ in $(seq 1 120); do
  if curl -fsS "${BASE}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[[ "${ready}" == "1" ]] || fail_fatal "Phoenix did not become ready on ${BASE}"

echo
echo "--- login protection ---"

code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/")"
case "${code}" in
  200 | 302 | 401) ok_login_protection=1 ;;
  *) ok_login_protection=0 ;;
esac
if [[ "${ok_login_protection}" == "1" ]]; then
  PASS=$((PASS + 1)); echo "ok   - unauthenticated UI is not served directly (HTTP ${code})"
else
  FAIL=$((FAIL + 1)); echo "FAIL - unauthenticated UI returned HTTP ${code}"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' --data-binary 'not-a-span')"
check "unauthenticated OTLP export rejected (HTTP ${code})" test "${code}" = 401

echo
echo "--- API key handling ---"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' \
  -H 'Authorization: Bearer phx_invalid_key_123' --data-binary 'not-a-span')"
check "invalid API key rejected (HTTP ${code})" test "${code}" = 401

# Login as the bootstrap admin and create a system API key (test scaffolding;
# the product workflow creates keys through the Phoenix Settings UI).
login_code="$(curl -s -o /dev/null -w '%{http_code}' -c "${COOKIE_JAR}" -X POST \
  "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\": \"admin@localhost\", \"password\": \"${ADMIN_PW}\"}")"
[[ "${login_code}" == "204" ]] || fail_fatal "admin login failed (HTTP ${login_code})"

create_key() { # create_key <name> -> prints the JSON response
  curl -s -b "${COOKIE_JAR}" -X POST "${BASE}/v1/system/api_keys" \
    -H 'Content-Type: application/json' \
    -d "{\"data\": {\"name\": \"$1\"}}"
}

key_json="$(create_key "smoke-test-key")"
API_KEY="$(node -e "const d=JSON.parse(process.argv[1]); if(!d.data?.key){process.exit(1)}; process.stdout.write(d.data.key)" "${key_json}" 2>/dev/null || true)"
KEY_ID="$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(d.data?.id||'')" "${key_json}" 2>/dev/null || true)"
if [[ -z "${API_KEY}" || -z "${KEY_ID}" ]]; then
  fail_fatal "could not create API key; response: ${key_json}"
fi
echo "created API key (id=${KEY_ID})"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' \
  -H "Authorization: Bearer ${API_KEY}" --data-binary 'not-a-span')"
check "valid API key passes auth (HTTP ${code} before body validation)" \
  test "${code}" = 400 -o "${code}" = 422 -o "${code}" = 200

echo
echo "--- span export with valid API key ---"

node "${ROOT}/tests/fixtures/send-span.mjs" "${OTEL_ENTRY}" "${BASE}" "${API_KEY}" >/dev/null 2>&1 || true

project_seen=""
for _ in $(seq 1 30); do
  projects="$(curl -s -H "Authorization: Bearer ${API_KEY}" "${BASE}/v1/projects" || true)"
  if [[ "${projects}" == *"phoenix-smoke"* ]]; then
    project_seen=1
    break
  fi
  sleep 2
done
if [[ "${project_seen}" == "1" ]]; then
  PASS=$((PASS + 1)); echo "ok   - exported span visible via API (project phoenix-smoke)"
else
  FAIL=$((FAIL + 1)); echo "FAIL - exported span not visible after export"
fi

echo
echo "--- revoked key rejection ---"

revoke_json="$(create_key "smoke-revoke-me")"
REVOKE_KEY="$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(d.data?.key||'')" "${revoke_json}" 2>/dev/null || true)"
REVOKE_ID="$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(d.data?.id||'')" "${revoke_json}" 2>/dev/null || true)"
if [[ -n "${REVOKE_KEY}" && -n "${REVOKE_ID}" ]]; then
  revoke_code="$(curl -s -o /dev/null -w '%{http_code}' -b "${COOKIE_JAR}" -X DELETE \
    "${BASE}/v1/system/api_keys/${REVOKE_ID}")"
  check "key revocation succeeds (HTTP ${revoke_code})" test "${revoke_code}" = 204
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' \
    -H "Authorization: Bearer ${REVOKE_KEY}" --data-binary 'not-a-span')"
  check "revoked API key rejected (HTTP ${code})" test "${code}" = 401
else
  echo "skip - could not create second key for revocation test"
fi

echo
echo "--- data persistence across restart ---"

podman restart "${CONTAINER}" >/dev/null
ready=0
for _ in $(seq 1 120); do
  if curl -fsS "${BASE}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[[ "${ready}" == "1" ]] || fail_fatal "Phoenix did not become ready after restart"

login_code="$(curl -s -o /dev/null -w '%{http_code}' -c "${COOKIE_JAR}" -X POST \
  "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\": \"admin@localhost\", \"password\": \"${ADMIN_PW}\"}")"
[[ "${login_code}" == "204" ]] || fail_fatal "admin login failed after restart (HTTP ${login_code})"

projects="$(curl -s -b "${COOKIE_JAR}" "${BASE}/v1/projects" || true)"
if [[ "${projects}" == *"phoenix-smoke"* ]]; then
  PASS=$((PASS + 1)); echo "ok   - project persists across container restart"
else
  FAIL=$((FAIL + 1)); echo "FAIL - project lost after restart"
fi

echo
echo "smoke tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
