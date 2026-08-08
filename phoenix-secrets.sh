#!/usr/bin/env bash
#
# phoenix-secrets.sh - generate and store secrets for the local Phoenix
# deployment. Secrets are stored either in a gitignored .env file or in the
# macOS Keychain. Values are never printed by phoenix-start.sh; this helper is
# the only place that reads and writes them.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PHOENIX_ENV_FILE:-${SCRIPT_DIR}/.env}"
ENV_EXAMPLE="${PHOENIX_ENV_EXAMPLE:-${SCRIPT_DIR}/.env.example}"
KEYCHAIN_SERVICE="${PHOENIX_KEYCHAIN_SERVICE:-phoenix-local}"
KEYCHAIN_ACCOUNT="${PHOENIX_KEYCHAIN_ACCOUNT:-${USER:-$(whoami)}}"

usage() {
  cat <<'EOF'
phoenix-secrets.sh - manage secrets for the local Phoenix deployment

Usage:
  phoenix-secrets.sh init [--force]
      Create .env from .env.example with a generated PHOENIX_SECRET and
      PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD. Refuses to overwrite an
      existing .env unless --force is given. Sets permissions to 600.

  phoenix-secrets.sh generate secret|password
      Print a freshly generated value (internal use; also useful for
      pre-seeding a Keychain item by piping the output).

  phoenix-secrets.sh keychain:set <NAME>
      Store a secret in the macOS Keychain. The value is read from stdin so it
      does not appear in shell history or process listings.

  phoenix-secrets.sh keychain:get <NAME>
      Print a secret stored in the macOS Keychain. Internal use by
      phoenix-start.sh; avoid running interactively.

  phoenix-secrets.sh keychain:check <NAME>
      Exit 0 if the secret exists in the Keychain, 1 otherwise.

  phoenix-secrets.sh keychain:delete <NAME>
      Remove a secret from the macOS Keychain.

  phoenix-secrets.sh keychain:init
      Generate PHOENIX_SECRET and PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD,
      store both in the macOS Keychain, and print the bootstrap next steps.

  phoenix-secrets.sh help
      Show this help.

Environment:
  PHOENIX_KEYCHAIN_SERVICE   Keychain service name (default: phoenix-local)
  PHOENIX_KEYCHAIN_ACCOUNT   Keychain account name (default: $USER)
  PHOENIX_ENV_FILE           Override the .env path (default: <dir>/.env)

Supported secret names: PHOENIX_SECRET, PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD,
PHOENIX_API_KEY.
EOF
}

# --- generators --------------------------------------------------------------

# Phoenix requires PHOENIX_SECRET to be >= 32 chars with at least one digit and
# one lowercase letter. A 64-char lowercase hex string satisfies this.
generate_secret() {
  openssl rand -hex 32
}

# Generates a 24-character password containing upper, lower, digit, and symbol
# classes (satisfies PHOENIX_ENABLE_STRONG_PASSWORD_POLICY). The character set
# deliberately excludes '#', '=', ' ', quotes, '$', and backticks so values are
# safe inside the simple .env parser.
generate_password() {
  local upper="ABCDEFGHJKLMNPQRSTUVWXYZ"
  local lower="abcdefghijkmnopqrstuvwxyz"
  local digit="23456789"
  local symbol="!@%^&*()-_+[]{}"
  local pool="${upper}${lower}${digit}${symbol}"
  local classes=("${upper}" "${lower}" "${digit}" "${symbol}")
  local pw="" c idx i byte

  for c in "${classes[@]}"; do
    byte="$(od -An -N1 -tu2 /dev/urandom | tr -d ' ')"
    idx=$((byte % ${#c}))
    pw+="${c:idx:1}"
  done
  for ((i = 4; i < 24; i++)); do
    byte="$(od -An -N1 -tu2 /dev/urandom | tr -d ' ')"
    idx=$((byte % ${#pool}))
    pw+="${pool:idx:1}"
  done
  printf '%s' "${pw}"
}

# --- .env ---------------------------------------------------------------------

cmd_init() {
  local force="${1:-}"
  if [[ -f "${ENV_FILE}" && "${force}" != "--force" ]]; then
    echo "Error: ${ENV_FILE} already exists. Use --force to overwrite." >&2
    exit 1
  fi
  if [[ ! -f "${ENV_EXAMPLE}" ]]; then
    echo "Error: ${ENV_EXAMPLE} not found. Cannot create ${ENV_FILE}." >&2
    exit 1
  fi

  local secret password
  secret="$(generate_secret)"
  password="$(generate_password)"

  {
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        PHOENIX_SECRET=*)
          printf 'PHOENIX_SECRET="%s"\n' "${secret}"
          ;;
        PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=*)
          printf 'PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD="%s"\n' "${password}"
          ;;
        *)
          printf '%s\n' "${line}"
          ;;
      esac
    done < "${ENV_EXAMPLE}"
  } > "${ENV_FILE}"

  chmod 600 "${ENV_FILE}"
  echo "Created ${ENV_FILE} (permissions 600)."
  echo
  echo "Next steps:"
  echo "  1. ./phoenix-start.sh"
  echo "  2. Open http://127.0.0.1:6006 and log in as admin@localhost with the"
  echo "     initial admin password stored in ${ENV_FILE}."
  echo "  3. Change the admin password in the UI."
  echo "  4. Create a system API key in Phoenix Settings and store it:"
  echo "     PHOENIX_API_KEY=<key> ./phoenix-secrets.sh keychain:set PHOENIX_API_KEY"
  echo "     or add PHOENIX_API_KEY=<key> to ${ENV_FILE}."
}

# --- Keychain -----------------------------------------------------------------

keychain_set() {
  local name="$1" value
  IFS= read -r value || true
  if [[ -z "${value}" ]]; then
    echo "Error: no value provided on stdin for ${name}." >&2
    exit 1
  fi
  security add-generic-password \
    -U \
    -a "${KEYCHAIN_ACCOUNT}" \
    -s "${KEYCHAIN_SERVICE}" \
    -w "${value}" \
    "${name}"
  echo "Stored ${name} in Keychain (service=${KEYCHAIN_SERVICE}, account=${KEYCHAIN_ACCOUNT})."
}

keychain_get() {
  local name="$1" value
  if ! value="$(security find-generic-password -a "${KEYCHAIN_ACCOUNT}" -s "${KEYCHAIN_SERVICE}" -w "${name}" 2>/dev/null)"; then
    echo "Error: ${name} is not in the Keychain (service=${KEYCHAIN_SERVICE}, account=${KEYCHAIN_ACCOUNT})." >&2
    exit 1
  fi
  printf '%s' "${value}"
}

keychain_check() {
  local name="$1"
  if security find-generic-password -a "${KEYCHAIN_ACCOUNT}" -s "${KEYCHAIN_SERVICE}" "${name}" >/dev/null 2>&1; then
    echo "present"
    return 0
  fi
  echo "missing"
  return 1
}

keychain_delete() {
  local name="$1"
  security delete-generic-password -a "${KEYCHAIN_ACCOUNT}" -s "${KEYCHAIN_SERVICE}" "${name}"
  echo "Deleted ${name} from Keychain (service=${KEYCHAIN_SERVICE}, account=${KEYCHAIN_ACCOUNT})."
}

cmd_keychain_init() {
  local secret password
  secret="$(generate_secret)"
  password="$(generate_password)"

  printf '%s' "${secret}" | keychain_set PHOENIX_SECRET
  printf '%s' "${password}" | keychain_set PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD

  echo
  echo "Secrets are stored in the Keychain (service=${KEYCHAIN_SERVICE}, account=${KEYCHAIN_ACCOUNT})."
  echo
  echo "Next steps:"
  echo "  1. In ${ENV_FILE}, set PHOENIX_SECRET_SOURCE=keychain (see .env.example)."
  echo "  2. ./phoenix-start.sh"
  echo "  3. Open http://127.0.0.1:6006 and log in as admin@localhost with the"
  echo "     initial admin password from the Keychain (Keychain Access)."
  echo "  4. Change the admin password in the UI."
  echo "  5. Create a system API key in Phoenix Settings and store it:"
  echo "     PHOENIX_API_KEY=<key> ./phoenix-secrets.sh keychain:set PHOENIX_API_KEY"
}

# --- dispatch -----------------------------------------------------------------

case "${1:-}" in
  init)
    cmd_init "${2:-}"
    ;;
  generate)
    case "${2:-}" in
      secret) generate_secret ;;
      password) generate_password ;;
      *)
        echo "Error: generate expects 'secret' or 'password'." >&2
        exit 2
        ;;
    esac
    ;;
  keychain:set)
    [[ -n "${2:-}" ]] || { echo "Error: keychain:set requires a secret name." >&2; exit 2; }
    keychain_set "$2"
    ;;
  keychain:get)
    [[ -n "${2:-}" ]] || { echo "Error: keychain:get requires a secret name." >&2; exit 2; }
    keychain_get "$2"
    ;;
  keychain:check)
    [[ -n "${2:-}" ]] || { echo "Error: keychain:check requires a secret name." >&2; exit 2; }
    keychain_check "$2"
    ;;
  keychain:delete)
    [[ -n "${2:-}" ]] || { echo "Error: keychain:delete requires a secret name." >&2; exit 2; }
    keychain_delete "$2"
    ;;
  keychain:init)
    cmd_keychain_init
    ;;
  help | --help | -h)
    usage
    ;;
  *)
    echo "Error: unknown command '${1:-}'." >&2
    usage
    exit 2
    ;;
esac
