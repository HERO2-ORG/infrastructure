# Monitoring

The internal VM runs the central monitoring stack:

- Prometheus
- Alertmanager
- Grafana
- blackbox-exporter
- node-exporter
- cAdvisor

App VMs run only monitoring clients:

- node-exporter
- cAdvisor

## Alert Policy

Slack receives only `severity="critical"` alerts. Resolved notifications are disabled.

Current critical alerts:

| Alert | Meaning |
|---|---|
| `ServerDown` | Prometheus cannot scrape a VM's node-exporter. |
| `DiskUsageCritical` | `/` or `/srv*` disk usage is above 90% for 10 minutes. |
| `DiskWillFillSoon` | Disk is predicted to fill within 24 hours. |
| `MemoryExhaustionCritical` | Available memory is below 5% for 10 minutes. |
| `HostSaturationCritical` | CPU usage and load are both sustained at critical levels. |
| `PublicEndpointDown` | A configured public endpoint fails from internal monitoring for 3 minutes. |
| `TlsCertificateRenewalFailing` | A probed TLS certificate expires in less than 7 days, which means automatic renewal is likely broken. |

There are intentionally no Slack alerts for moderate CPU, moderate load, warning-level memory, or resolved states.

## TLS Renewal

TLS certificates are not a manual operations task. Traefik uses Let's Encrypt HTTP-01 renewal and stores ACME state in the persistent stack directory:

- app VMs: `/srv/stack/backend/letsencrypt`
- internal VM: `/srv/stack/monitoring/letsencrypt`

Certificates should renew automatically while:

- DNS points to the correct VM
- ports `80` and `443` are reachable
- Traefik is running
- the ACME storage directory persists across deploys
- Let's Encrypt has not rate-limited issuance

The TLS alert exists only as a failure detector for that automation.

## HTTP Probes

Endpoint probes are configured in `ansible/group_vars/internal.yml` under `monitoring_http_probes`.

Current probes:

- `https://api.dev.hero2.org/health`
- `https://api.hero2.org/health`
- `https://auth.dev.hero2.org`
- `https://auth.hero2.org`
- `https://dev.hero2.org`
- `https://hero2.org`
- `https://labeling.internal.hero2.org`

Use `http_2xx` for strict health endpoints. Use `http_2xx_3xx` for websites and OAuth-protected pages where redirects are expected.

## Updating Alerts

Alert rules live in:

```text
ansible/roles/monitoring-server/templates/alert-rules.yml.j2
```

Alert routing lives in:

```text
ansible/roles/monitoring-server/templates/alertmanager.yml.j2
```

After changes:

```bash
cd ansible
make check-internal
make apply-internal
```
