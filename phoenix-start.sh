#!/usr/bin/env bash
#
# phoenix-start.sh - start the local Arize Phoenix Podman deployment.
#
# Loads .env (or the macOS Keychain) and, when authentication is configured,
# passes Phoenix's native auth settings to a newly created container. Existing
# containers are started as-is and are never silently recreated; use
# PHOENIX_RECREATE=1 (or --recreate) to apply configuration changes.
#
set -euo pipefail

# Pin all podman calls to the dedicated phoenix machine (override with PHOENIX_MACHINE).
export CONTAINER_CONNECTION="${PHOENIX_MACHINE:-phoenix}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${PHOENIX_CONTAINER_NAME:-phoenix}"
VOLUME_NAME="${PHOENIX_VOLUME_NAME:-phoenix_data}"
PHOENIX_VERSION="${PHOENIX_VERSION:-latest}"
IMAGE="${PHOENIX_IMAGE:-docker.io/arizephoenix/phoenix:${PHOENIX_VERSION}}"
ENV_FILE="${PHOENIX_ENV_FILE:-${SCRIPT_DIR}/.env}"
DRY_RUN="${PHOENIX_DRY_RUN:-0}"
RECREATE="${PHOENIX_RECREATE:-0}"

for arg in "$@"; do
  case "${arg}" in
    --recreate) RECREATE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      cat <<'EOF'
Usage: ./phoenix-start.sh [--recreate] [--dry-run]

  --recreate   Remove and recreate the phoenix container with the current
               configuration. The phoenix_data volume is preserved.
  --dry-run    Print the podman commands that would run without executing them.
               Secret values are masked.

Environment: PHOENIX_MACHINE, PHOENIX_ENV_FILE, PHOENIX_CONTAINER_NAME, PHOENIX_VOLUME_NAME,
PHOENIX_VERSION, PHOENIX_IMAGE, PHOENIX_RECREATE, PHOENIX_DRY_RUN,
PHOENIX_SECRET_SOURCE, PHOENIX_KEYCHAIN_SERVICE, PHOENIX_KEYCHAIN_ACCOUNT.
EOF
      exit 0
      ;;
  esac
done

# --- helpers ------------------------------------------------------------------

die() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

# Load KEY=VALUE lines without expansion. Comments start with '#'. Surrounding
# quotes are stripped. Generated secrets never contain '#', '=', or quotes, so
# this simple parser is safe for this deployment.
load_env() {
  local file="$1" line key value
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ ${#value} -ge 2 ]] && [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 ]] && [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
    export "${key}=${value}"
  done < "${file}"
}

# podman wrapper. In dry-run mode nothing is executed and secret values are
# masked; in normal mode this simply delegates to the real (or test-mocked)
# podman binary.
podman() {
  if [[ "${DRY_RUN}" != "1" ]]; then
    command podman "$@"
    return
  fi
  case "${1:-}" in
    info) return 0 ;;
    container)
      case "${2:-}" in
        exists) return 1 ;; # simulate a fresh install
      esac
      return 0
      ;;
    volume)
      [[ "${2:-}" == "exists" ]] && return 1
      return 0
      ;;
    port)
      echo "127.0.0.1:6006 -> 6006"
      echo "127.0.0.1:4317 -> 4317"
      return 0
      ;;
    run)
      printf '[dry-run] podman' >&2
      local arg
      for arg in "$@"; do
        case "${arg}" in
          PHOENIX_SECRET=* | PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=* | PHOENIX_API_KEY=*)
            printf ' %s=****' "${arg%%=*}" >&2
            ;;
          *)
            printf ' %q' "${arg}" >&2
            ;;
        esac
      done
      echo >&2
      return 0
      ;;
    *) return 0 ;;
  esac
}

# --- prerequisites -------------------------------------------------------------

if [[ "${DRY_RUN}" != "1" ]]; then
  if ! command -v podman >/dev/null 2>&1; then
    die "podman is not installed or is not on PATH."
  fi
  if ! podman info >/dev/null 2>&1; then
    die "Podman is not reachable. Start the Podman machine first: podman machine start ${PHOENIX_MACHINE:-phoenix}"
  fi
fi

# --- configuration -------------------------------------------------------------

load_env "${ENV_FILE}"

# Warn about world-readable .env files.
if [[ -f "${ENV_FILE}" ]] && [[ "${PHOENIX_SECRET_SOURCE:-env}" != "keychain" ]]; then
  perms="$(stat -f '%Lp' "${ENV_FILE}" 2>/dev/null || true)"
  if [[ -n "${perms}" && "${perms}" != "600" ]]; then
    warn "${ENV_FILE} permissions are ${perms}; run: chmod 600 ${ENV_FILE}"
  fi
fi

# Resolve secrets from the macOS Keychain when Keychain mode is selected. The
# same environment variable names are used regardless of storage mode.
if [[ "${PHOENIX_SECRET_SOURCE:-env}" == "keychain" ]]; then
  for name in PHOENIX_SECRET PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD PHOENIX_API_KEY; do
    if value="$("${SCRIPT_DIR}/phoenix-secrets.sh" keychain:get "${name}" 2>/dev/null)"; then
      export "${name}=${value}"
    fi
  done
fi

AUTH_ENABLED=0
if [[ "${PHOENIX_ENABLE_AUTH:-false}" == "true" ]]; then
  AUTH_ENABLED=1
fi

# --- container state -------------------------------------------------------------

CONTAINER_EXISTS=0
if podman container exists "${CONTAINER_NAME}"; then
  CONTAINER_EXISTS=1
fi

if [[ "${RECREATE}" == "1" && "${CONTAINER_EXISTS}" == "1" ]]; then
  echo "Recreating container ${CONTAINER_NAME} (the ${VOLUME_NAME} volume is preserved)..."
  podman rm -f "${CONTAINER_NAME}" >/dev/null
  CONTAINER_EXISTS=0
fi

# --- validation -----------------------------------------------------------------

if [[ "${AUTH_ENABLED}" == "1" ]]; then
  if [[ -z "${PHOENIX_SECRET:-}" ]]; then
    die "PHOENIX_ENABLE_AUTH=true requires PHOENIX_SECRET. Generate one with: ./phoenix-secrets.sh init (or keychain:init)."
  fi
  if [[ ${#PHOENIX_SECRET} -lt 32 ]] \
    || ! [[ "${PHOENIX_SECRET}" =~ [0-9] ]] \
    || ! [[ "${PHOENIX_SECRET}" =~ [a-z] ]]; then
    die "PHOENIX_SECRET must be at least 32 characters with at least one digit and one lowercase letter. Generate one with: ./phoenix-secrets.sh init"
  fi

  if [[ "${CONTAINER_EXISTS}" == "0" ]]; then
    # A fresh container means a potential first startup, so the initial admin
    # password is required. Phoenix only uses it when no admin account exists.
    if [[ -z "${PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD:-}" ]]; then
      die "A new Phoenix container requires PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD (used only on first startup to create admin@localhost). Generate one with: ./phoenix-secrets.sh init"
    fi
    local_min=8
    if [[ "${PHOENIX_ENABLE_STRONG_PASSWORD_POLICY:-false}" == "true" ]]; then
      local_min=12
    fi
    if [[ ${#PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD} -lt ${local_min} ]]; then
      die "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD must be at least ${local_min} characters."
    fi
  fi

  if [[ -z "${PHOENIX_API_KEY:-}" ]]; then
    warn "PHOENIX_API_KEY is not set: authenticated trace export (pi-phoenix) will be rejected by Phoenix until a system API key is created in the UI and stored (see README.md)."
  elif [[ ${#PHOENIX_API_KEY} -lt 8 ]]; then
    warn "PHOENIX_API_KEY looks too short to be valid; trace export will likely be rejected."
  fi
else
  if [[ -z "${PHOENIX_SECRET:-}" && -n "${PHOENIX_API_KEY:-}" ]]; then
    warn "PHOENIX_API_KEY is set but PHOENIX_ENABLE_AUTH is not true; Phoenix will ignore the key."
  fi
fi

# --- existing container ------------------------------------------------------------

if [[ "${CONTAINER_EXISTS}" == "1" ]]; then
  status="$(podman container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")"
  if [[ "${status}" == "running" ]]; then
    echo "Phoenix is already running in container ${CONTAINER_NAME}."
    podman port "${CONTAINER_NAME}"
  else
    echo "Starting existing Phoenix container ${CONTAINER_NAME}..."
    podman start "${CONTAINER_NAME}"
    podman port "${CONTAINER_NAME}"
  fi

  # Report (without acting on) auth configuration drift between .env and the
  # container's creation-time environment.
  existing_env="$(podman container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
  container_auth=no
  if grep -q '^PHOENIX_ENABLE_AUTH=true$' <<<"${existing_env}"; then
    container_auth=yes
  fi
  current_auth=no
  if [[ "${AUTH_ENABLED}" == "1" ]]; then
    current_auth=yes
  fi
  if [[ "${container_auth}" != "${current_auth}" ]]; then
    if [[ "${current_auth}" == "yes" ]]; then
      warn "This container was created without authentication. To enable authentication now (keeps the ${VOLUME_NAME} volume): PHOENIX_RECREATE=1 ./phoenix-start.sh"
    else
      warn "This container was created with authentication enabled. To disable it: PHOENIX_RECREATE=1 ./phoenix-start.sh"
    fi
  elif [[ "${AUTH_ENABLED}" == "1" ]]; then
    # Auth state matches; warn only when the signing secret differs from the
    # container's creation-time secret (a breaking change per the spec).
    if ! grep -qF "PHOENIX_SECRET=${PHOENIX_SECRET}" <<<"${existing_env}"; then
      warn "PHOENIX_SECRET differs from this container's creation-time secret; existing sessions will be invalidated. To apply: PHOENIX_RECREATE=1 ./phoenix-start.sh"
    fi
  fi
  exit 0
fi

# --- create container ---------------------------------------------------------------

if ! podman volume exists "${VOLUME_NAME}"; then
  echo "Creating persistent volume ${VOLUME_NAME}..."
  podman volume create "${VOLUME_NAME}" >/dev/null
fi

echo "Pulling ${IMAGE}..."
podman pull "${IMAGE}"

declare -a RUN_ARGS=(
  --detach
  --name "${CONTAINER_NAME}"
  --restart=unless-stopped
  --publish 127.0.0.1:6006:6006
  --publish 127.0.0.1:4317:4317
  --env PHOENIX_WORKING_DIR=/mnt/data
  --volume "${VOLUME_NAME}:/mnt/data"
)

# Authentication settings are only passed when creating (or explicitly
# recreating) the container.
if [[ "${AUTH_ENABLED}" == "1" ]]; then
  RUN_ARGS+=(--env "PHOENIX_ENABLE_AUTH=true")
  RUN_ARGS+=(--env "PHOENIX_SECRET=${PHOENIX_SECRET}")
  RUN_ARGS+=(--env "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=${PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}")
  RUN_ARGS+=(--env "PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=${PHOENIX_ENABLE_STRONG_PASSWORD_POLICY:-false}")
fi

echo "Starting Phoenix..."
podman run "${RUN_ARGS[@]}" "${IMAGE}"

# --- safe next steps ---------------------------------------------------------------

echo
echo "Phoenix started: http://localhost:6006"
echo "OTLP/HTTP traces: http://127.0.0.1:6006/v1/traces"
echo "OTLP/gRPC:        http://127.0.0.1:4317"
if [[ "${AUTH_ENABLED}" == "1" ]]; then
  echo
  echo "Authentication is enabled."
  echo "  1. Open http://127.0.0.1:6006 and log in as admin@localhost with the"
  echo "     initial admin password (stored in .env or the Keychain)."
  echo "  2. Change the admin password in the UI."
  echo "  3. Create a system API key in Settings and store it (see README.md)."
  if [[ -z "${PHOENIX_API_KEY:-}" ]]; then
    echo "  Note: no PHOENIX_API_KEY is configured yet, so trace export is rejected."
  fi
else
  echo
  echo "Authentication is disabled (anonymous mode). To enable it, create .env"
  echo "with PHOENIX_ENABLE_AUTH=true (see .env.example) and recreate the container."
fi
echo
echo "Useful commands:"
echo "  podman logs -f ${CONTAINER_NAME}"
echo "  podman stop ${CONTAINER_NAME}"
echo "  podman start ${CONTAINER_NAME}"
