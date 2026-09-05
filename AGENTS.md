# AGENTS.md

Documentation for available agents in this Phoenix deployment

## Phoenix Management Agent

- **Purpose**: Control Phoenix container lifecycle (start/stop/restart)
- **Setup**: Already integrated via bash commands
- **Usage**: Trigger with `runs.run('phoenix-management', {task: 'start'})`

## OpenTelemetry Agent

- **Purpose**: Optimize trace collection with dynamic agent logic
- **Setup**: Register via pi-phoenix extension configuration
- **Usage**: Configure OTLP endpoint adjustments automatically

## Test Automation Agent

- **Purpose**: Run deployment/smoke tests through pi
- **Setup**: Point to `tests/` directory
- **Usage**: `runs.run('test-automation', {task: 'run-deployment-test'})`

## Security Audit Agent

- **Purpose**: Verify secrets and permission configurations
- **Setup**: Uses read tool to check .env permissions
- **Usage**: `runs.run('security-audit', {task: 'check-secrets'})`

## Phoenix Update Runbook

Use this workflow when updating the running Phoenix deployment. Editing the
scripts or README is not a deployment; the update command must also be run.

1. Confirm the current runtime image before changing anything:

   ```bash
   CONTAINER_CONNECTION=phoenix podman ps -a --filter name=phoenix \\
     --format '{{.Names}} {{.Image}} {{.Status}}'
   CONTAINER_CONNECTION=phoenix podman inspect --format '{{.Config.Image}}' phoenix
   ```

2. Preview the update if the target release or configuration is uncertain:

   ```bash
   PHOENIX_VERSION=20.8.0-nonroot ./phoenix-update.sh --dry-run
   ```

3. Apply the update. This archives `phoenix_data`, pulls the image, recreates
   the container, and preserves the volume and authentication settings:

   ```bash
   PHOENIX_VERSION=20.8.0-nonroot ./phoenix-update.sh
   ```

   Use `--no-backup` only when a recent suitable archive already exists.

4. Verify the postcondition instead of relying only on the script output:

   ```bash
   CONTAINER_CONNECTION=phoenix podman ps --filter name=phoenix \\
     --format '{{.Names}} {{.Image}} {{.Status}}'
   CONTAINER_CONNECTION=phoenix podman inspect --format '{{.Config.Image}}' phoenix
   ```

   The output must show the requested image tag and a running container. If
   the UI still shows the previous release, refresh it or use a private tab;
   then verify the container image first. Do not delete `phoenix_data` to fix
   a stale UI.

5. Run the non-destructive checks after script changes:

   ```bash
   bash tests/update.test.sh
   bash tests/deployment.test.sh
   bash -n phoenix-start.sh phoenix-update.sh
   ```

When changing the default release, keep these values synchronized:
`phoenix-update.sh`, its help text, the update tests, and the README.
