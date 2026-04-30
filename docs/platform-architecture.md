# Platform Architecture

## VM Roles

VM roles are assigned only in `ansible/inventory/hosts.yml`.

| Role | Current IP | Purpose |
|---|---:|---|
| `production` | `62.146.168.92` | Production app stack and monitoring client exporters. |
| `staging` | `194.163.167.168` | Staging app stack and monitoring client exporters. |
| `internal` | `157.173.100.1` | Internal monitoring, internal proxy, and internal tooling. |

Playbooks target role groups, not instance names. Swapping a VM role should be an inventory change followed by a full Ansible run.

## Repository Responsibilities

This repo owns platform mechanics:

- VM inventory and role mapping
- base Docker installation
- UFW rules
- monitoring server on `internal`
- monitoring exporters on app VMs
- shared GitHub Actions
- shared CI/lint/release config

Service repositories own service mechanics:

- service deploy playbook under `deploy/`
- non-sensitive service config under `deploy/*.env`
- encrypted service vault under `deploy/secrets.yml.enc`
- service Docker Compose files
- service CI pipeline

## Ansible Layout

| Path | Purpose |
|---|---|
| `ansible/inventory/hosts.yml` | Source of truth for VM role to IP mapping. |
| `ansible/inventory/local.example.yml` | Template for local machine overrides. |
| `ansible/group_vars/` | Role and platform variables. |
| `ansible/playbooks/internal.yml` | Applies internal VM platform roles. |
| `ansible/playbooks/staging.yml` | Applies staging VM platform roles. |
| `ansible/playbooks/production.yml` | Applies production VM platform roles. |
| `ansible/roles/docker/` | Docker and Compose setup. |
| `ansible/roles/ufw/` | Firewall setup. |
| `ansible/roles/monitoring-server/` | Prometheus, Alertmanager, Grafana, blackbox-exporter. |
| `ansible/roles/monitoring-client/` | node-exporter and cAdvisor. |

## Service Deploy Flow

Service repos deploy themselves.

1. Service CI builds and pushes an image.
2. Service CI checks out this infrastructure repo for inventory and shared platform context.
3. Service CI decrypts its own `deploy/secrets.yml.enc`.
4. Service CI runs its own `deploy/playbook.yml`.
5. The service playbook writes the VM `.env`, updates Compose files, and starts the service.

The service developer should not need to know which IP currently hosts staging or production.
