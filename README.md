# Local Arize Phoenix with Podman

This directory contains a small local deployment for [Arize Phoenix](https://phoenix.arize.com/) using the already-installed Podman machine on macOS Apple Silicon.

The setup uses:

- Podman instead of Docker
- Phoenix with SQLite storage
- A persistent Podman volume
- Localhost-only port bindings
- Phoenix-native authentication (optional but recommended)
- No Docker Compose dependency

## Prerequisites

- macOS on Apple Silicon or another host supported by Podman
- Podman installed
- A running Podman machine
- Node.js (only for the smoke tests, which use `@arizeai/phoenix-otel`)

Check the Podman environment:

```bash
podman machine list
podman info
```

If the Podman machine is stopped, start it (the phoenix scripts pin all podman
calls to the dedicated `phoenix` machine; override with `PHOENIX_MACHINE`):

```bash
podman machine start phoenix
```

## Authentication model

The deployment uses Phoenix's built-in authentication. `phoenix-start.sh` passes these settings to a newly created container:

| Variable | Purpose |
| --- | --- |
| `PHOENIX_ENABLE_AUTH=true` | Enable authentication |
| `PHOENIX_SECRET` | Persistent JWT signing secret (>= 32 chars, at least one digit and one lowercase letter) |
| `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` | Password for the initial `admin@localhost` account; used only when no admin account exists yet |
| `PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true` | Require strong passwords in the Phoenix UI |

```text
phoenix-start.sh
  ├─ reads .env or macOS Keychain
  ├─ starts Phoenix with built-in authentication
  └─ publishes localhost ports
       │
       ├─ Browser → http://127.0.0.1:6006
       │            Phoenix login cookie/session
       │
       └─ pi-phoenix → OTLP HTTP /v1/traces
                      Authorization: Bearer <system API key>
```

The browser authenticates with Phoenix's web session. `pi-phoenix` never logs in; it sends a system API key through the OTLP exporter (`@arizeai/phoenix-otel` sends it as `Authorization: Bearer <key>`). Session links in the pi UI assume the browser already has a valid Phoenix login session.

## First-run bootstrap

1. Create a `.env` with generated secrets:

   ```bash
   ./phoenix-secrets.sh init
   ```

   or, to store secrets in the macOS Keychain instead:

   ```bash
   ./phoenix-secrets.sh keychain:init
   ```

2. Start Phoenix:

   ```bash
   ./phoenix-start.sh
   ```

3. Open <http://localhost:6006> and log in as `admin@localhost` with the initial admin password (from `.env` or the Keychain).
4. Change the admin password in the UI.
5. Create a system API key in **Settings → System API Keys** (or the Settings API key tab).
6. Store the key so `pi-phoenix` can use it:

   ```bash
   PHOENIX_API_KEY=<key> ./phoenix-secrets.sh keychain:set PHOENIX_API_KEY
   ```

   or add `PHOENIX_API_KEY=<key>` to `.env`.
7. Restart Pi from a shell without a stale `PHOENIX_API_KEY` export (with `~/.env.phoenix` in place) so the SDK picks up `PHOENIX_API_KEY` / `PHOENIX_COLLECTOR_ENDPOINT`, then verify traces appear in Phoenix.
8. Click a session link in Pi in a browser that is logged into Phoenix.

## Start Phoenix

Run:

```bash
./phoenix-start.sh
```

The script will:

1. Load `.env` (or resolve secrets from the macOS Keychain).
2. Validate `PHOENIX_SECRET`, the initial admin password (on first startup), and `PHOENIX_API_KEY`.
3. Check that Podman is available and the Podman machine is reachable.
4. Create the persistent `phoenix_data` volume if necessary.
5. Pull the Phoenix image if it is not already available.
6. Start Phoenix as a detached container, passing authentication settings only when creating (or explicitly recreating) the container.

Existing containers are **never silently recreated**. If your `.env` configuration differs from the container's creation-time environment, the script prints a warning; apply changes with:

```bash
PHOENIX_RECREATE=1 ./phoenix-start.sh
```

The `phoenix_data` volume is preserved across recreation.

Preview the commands without executing them (secret values are masked):

```bash
PHOENIX_DRY_RUN=1 ./phoenix-start.sh
```

The default image is `docker.io/arizephoenix/phoenix:latest`.

For a reproducible setup, pin a Phoenix release:

```bash
PHOENIX_VERSION=19.17.0 ./phoenix-start.sh
```

Alternatively, provide a complete image reference:

```bash
PHOENIX_IMAGE=docker.io/arizephoenix/phoenix:19.17.0 ./phoenix-start.sh
```

## Configuration

Copy `.env.example` to `.env` (or run `./phoenix-secrets.sh init`) and fill in the values:

```dotenv
PHOENIX_ENABLE_AUTH=true
PHOENIX_SECRET=generated-long-secret
PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=generated-admin-password
PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true

PHOENIX_COLLECTOR_ENDPOINT=http://127.0.0.1:6006
PHOENIX_API_KEY=generated-from-phoenix-ui
PI_PHOENIX_PROJECT=phoenix
```

`.env` must be user-readable only (`chmod 600`) and must never be committed (see `.gitignore`). The start script and helper never print secret values.

`PHOENIX_COLLECTOR_ENDPOINT`, `PHOENIX_API_KEY`, and `PI_PHOENIX_PROJECT` are consumed by the `pi-phoenix` extension. **Do not `source` `.env` into a shell** - generated secrets can contain `$`, `&`, `*`, and `"`, which corrupt or break values when sourced. Instead, let the phoenix SDK (bundled with pi-phoenix) read them from its hand-off file, which is discovered by walking up from pi's working directory (only `PHOENIX_`-prefixed keys are read; process env wins over the file):

```bash
ln -sf ~/project/phoenix/.env ~/.env.phoenix
```

Then start pi from a shell that has no stale `PHOENIX_API_KEY` exported (`unset PHOENIX_API_KEY` or a fresh shell). `PI_PHOENIX_PROJECT` is not `PHOENIX_`-prefixed, so it must come from the environment; it defaults to the git repo/cwd basename (i.e. `phoenix`).

### macOS Keychain mode

Secrets (`PHOENIX_SECRET`, `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD`, `PHOENIX_API_KEY`) can be stored in the macOS Keychain instead of `.env`:

```dotenv
PHOENIX_SECRET_SOURCE=keychain
PHOENIX_KEYCHAIN_SERVICE=phoenix-local
PHOENIX_KEYCHAIN_ACCOUNT=$USER
```

The same environment variable names reach the container regardless of storage mode. Helper commands:

```bash
./phoenix-secrets.sh keychain:init                          # generate + store secret and admin password
PHOENIX_API_KEY=<key> ./phoenix-secrets.sh keychain:set PHOENIX_API_KEY
./phoenix-secrets.sh keychain:check PHOENIX_API_KEY         # exit 0 if present
./phoenix-secrets.sh keychain:get PHOENIX_API_KEY           # internal use; prints the value
./phoenix-secrets.sh keychain:delete PHOENIX_API_KEY
```

## Phoenix endpoints

| Endpoint | Purpose |
| --- | --- |
| `http://localhost:6006` | Phoenix web UI (login required when auth is enabled) |
| `http://127.0.0.1:6006/v1/traces` | OTLP over HTTP (requires `Authorization: Bearer <API key>` when auth is enabled) |
| `http://127.0.0.1:4317` | OTLP over gRPC |

Both ports are bound to `127.0.0.1`, so the service is not exposed directly to the local network.

## Configure OpenTelemetry

For an application running directly on the host using OTLP over HTTP with authentication enabled:

```bash
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:6006/v1/traces
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_TRACES_HEADERS="Authorization=Bearer ${PHOENIX_API_KEY}"
```

For OTLP over gRPC:

```bash
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:4317
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=grpc
```

If the instrumented application also runs inside a Podman container, `localhost` refers to that application container. Put both containers on a shared Podman network and use the Phoenix container name instead:

```text
http://phoenix:6006/v1/traces
```

## pi-phoenix integration

The extension reads `PHOENIX_COLLECTOR_ENDPOINT` and `PHOENIX_API_KEY` from its environment and relies on `@arizeai/phoenix-otel` to send the key as `Authorization: Bearer <key>`. Requirements for the authenticated deployment:

- Set both variables where pi runs via `~/.env.phoenix` (see Configuration); process env vars override the file, so a stale `PHOENIX_API_KEY` exported into the shell wins and must be unset.
- When authentication is enabled but `PHOENIX_API_KEY` is missing, `phoenix-start.sh` warns; pi keeps running (export failures are non-fatal to agent execution).
- The API key must never be put in spans, status text, logs, or URLs. The extension's status text only contains a session link.
- Endpoint normalization (`/v1/traces` suffix) and disabled tracing (`PI_PHOENIX_ENABLE=false`) are preserved.

Verification against the installed `pi-phoenix`:

- `PHOENIX_API_KEY` reaches `register({ apiKey })` in `src/trace/provider.ts` and is sent as a Bearer header by `@arizeai/phoenix-otel` (see `tests/smoke.test.sh`, which exercises the same library).
- For agent configuration details, see AGENTS.md.
- Extension source changes (e.g., a warning when authenticated export is configured without a key) live in the `pi-phoenix` checkout/contribution branch, not in this deployment.

## Key rotation

1. Create a replacement system API key in Phoenix Settings.
2. Store it (`keychain:set PHOENIX_API_KEY` or edit `.env`).
3. Restart Pi and confirm new traces are ingested.
4. Revoke the old key in Phoenix Settings.

## Migrating an existing anonymous installation

Existing anonymous installs keep their data but require an explicit migration:

1. Stop Phoenix: `./phoenix-stop.sh`.
2. Create `.env` with auth enabled (`./phoenix-secrets.sh init`).
3. Recreate the container so the auth environment is applied (the `phoenix_data` volume is preserved):

   ```bash
   PHOENIX_RECREATE=1 ./phoenix-start.sh
   ```

4. Complete the admin/API-key bootstrap (see First-run bootstrap). Existing data remains in the volume; future API access requires credentials.

Changing `PHOENIX_SECRET` is a breaking change: it invalidates existing auth tokens and sessions.

## Error handling

- **Missing API key**: non-fatal warning from `phoenix-start.sh`; pi keeps working.
- **Invalid/revoked key**: the exporter reports the endpoint and HTTP status, never the credential.
- **Phoenix unavailable**: the OTLP exporter retries in the background and does not block pi agent execution.
- **Expired browser session**: Phoenix redirects to login; pi needs no special recovery.

## Verify Phoenix

Check the container:

```bash
podman ps
podman port phoenix
podman logs --tail=100 phoenix
```

Check the UI endpoint (a login page is expected when auth is enabled):

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:6006/
```

## Tests

Deployment tests use a mocked `podman` and a mocked macOS `security` CLI; nothing is started:

```bash
./tests/deployment.test.sh
```

For agent-based test automation, refer to AGENTS.md.

```bash
./tests/smoke.test.sh
```

## Update Phoenix

Use the update script to create a volume archive, pull the non-root Phoenix
image, and recreate the container without deleting the persistent
`phoenix_data` volume:

```bash
./phoenix-update.sh
```

The default image is `docker.io/arizephoenix/phoenix:20.8.0-nonroot`. Select a
new release without editing the script:

```bash
PHOENIX_VERSION=20.2.0-nonroot ./phoenix-update.sh
```

Or provide a complete image reference:

```bash
PHOENIX_IMAGE=docker.io/arizephoenix/phoenix:19.20.0-nonroot ./phoenix-update.sh
```

The update stops before pulling or recreating if the archive fails. Skip the
archive only when you already have a suitable backup:

```bash
./phoenix-update.sh --no-backup
```

Preview the operations without changing Podman state:

```bash
./phoenix-update.sh --dry-run
```

The script preserves authentication settings from `.env` or the macOS
Keychain and never removes `phoenix_data`.

## Stop and restart

Stop Phoenix without deleting its data:

```bash
./phoenix-stop.sh
```

Restart it:

```bash
podman start phoenix
```

Or use the start script, which also starts an existing stopped container:

```bash
./phoenix-start.sh
```

View live logs:

```bash
podman logs -f phoenix
```

## Persistent data

Phoenix stores its SQLite database at `/mnt/data/phoenix.db` inside the container. The path is backed by the Podman volume `phoenix_data`.

Inspect the volume:

```bash
podman volume inspect phoenix_data
```

Removing the container does not remove the named volume:

```bash
podman rm -f phoenix
```

The data is intentionally reset only when the volume is explicitly removed:

```bash
podman volume rm phoenix_data
```

The volume removal is destructive. Secrets live in `.env` or the Keychain, never in the volume.

### Create a manual archive

Create a consistent archive of the complete Phoenix volume before an upgrade or
other major change:

```bash
./phoenix-archive.sh
```

The script stops Phoenix only if it was running, exports `phoenix_data`, writes
a SHA-256 checksum and recovery manifest, then restores the container to its
previous state. Archives are stored by default under
`~/Backups/phoenix/<UTC-timestamp>/`. Override the location when needed:

```bash
PHOENIX_ARCHIVE_DIR=/Volumes/backup/phoenix ./phoenix-archive.sh
```

Each archive directory contains:

- `phoenix_data.tar` — the exported Podman volume
- `phoenix_data.tar.sha256` — the archive checksum
- `manifest.txt` — image, volume, timestamp and recovery information

The archive contains Phoenix traces and may contain other sensitive data. The
script sets restrictive permissions on the archive directory and files. It
does not copy `.env` or macOS Keychain secrets; retain those separately for a
complete authenticated recovery.

To restore into a volume, stop and remove the target container without removing
its volume, create or select an empty volume, then import the archive:

```bash
podman volume import /path/to/phoenix_data.tar phoenix_data
```

Recreate Phoenix with the image recorded in `manifest.txt`, restore the
authentication settings separately, and run the smoke test or verify the UI
before treating the restoration as complete. Do not import an archive into a
non-empty volume without first confirming the intended result.

## Troubleshooting

### Podman is not reachable

Start the machine and retry:

```bash
podman machine list
podman machine start phoenix
./phoenix-start.sh
```

### Port already in use

Check which process is using a port:

```bash
lsof -nP -iTCP:6006 -sTCP:LISTEN
lsof -nP -iTCP:4317 -sTCP:LISTEN
```

Stop the conflicting service or change the port mapping in `phoenix-start.sh`.

### Phoenix is still starting

Phoenix runs database migrations during startup. Inspect the logs and wait until they contain `Phoenix is up and running`:

```bash
podman logs -f phoenix
```

### Forgot the admin password or the initial login fails

The initial admin password is only applied when the admin account is first created. To reset, either remove the volume (destructive) or use Phoenix's password-reset flow from the login page.

### Memory pressure

The current Podman machine has 2 GiB RAM. If additional containers are running or Phoenix is terminated by the system, increase the machine allocation:

```bash
podman machine stop phoenix
podman machine set --memory 4096 phoenix
podman machine start phoenix
```

## Optional PostgreSQL deployment

SQLite is appropriate for this single-user local setup. PostgreSQL can be added later when a multi-application or more production-like deployment is needed.

Phoenix requires PostgreSQL 14 or newer and uses the following environment variable:

```text
PHOENIX_SQL_DATABASE_URL=postgresql://<user>:<password>@<host>:5432/<database>
```

The current machine does not have a Docker Compose or Podman Compose provider, so the initial deployment intentionally uses `podman run`.

## Reference

Phoenix Docker deployment documentation:

<https://arize.com/docs/phoenix/self-hosting/deployment-options/docker>
