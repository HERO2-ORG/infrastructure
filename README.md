# Hero2 Infrastructure

Shared platform code for Hero2 repositories.

This repo owns VM topology, Ansible platform roles, shared GitHub composite actions, and shared CI configuration. Service repositories own their own application deployment config, application playbooks, and service vault files.

## Repository Map

| Path | Purpose |
|---|---|
| `ansible/` | VM inventory, base playbooks, and shared platform roles. |
| `.github/actions/` | Reusable composite GitHub Actions for service repositories. |
| `.github/workflows/` | Infrastructure repo automation. |
| `configs/` | Shared lint, release, commit, and link-check config. |
| `docs/` | Operational and architecture documentation. |
| `WORKFLOW.md` | Organization development workflow and PR conventions. |

## Main Docs

- [Platform architecture](docs/platform-architecture.md)
- [Operations](docs/operations.md)
- [Monitoring](docs/monitoring.md)
- [Shared CI actions and config](docs/shared-ci.md)
- [Development workflow](WORKFLOW.md)

## Quick Start

```bash
cd ansible
cp inventory/local.example.yml inventory/local.yml
make install
make ping-internal
make check-internal
```

`inventory/local.yml` is ignored by git and should contain machine-local Ansible settings such as `ansible_ssh_private_key_file`.

## Ownership Model

- Infrastructure repo: VM role mapping, Docker/UFW/monitoring platform roles, shared actions, shared CI config.
- Service repos: service-specific deploy playbooks, non-sensitive deploy config, encrypted service vaults, Docker Compose files.