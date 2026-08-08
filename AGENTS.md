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
- **Usage`: `runs.run('security-audit', {task: 'check-secrets'})`