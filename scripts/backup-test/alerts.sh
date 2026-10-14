#!/usr/bin/env bash
# Runs the backup alert unit tests against the rendered alert rules with the
# promtool of the Prometheus version the monitoring stack runs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
grep -v '{% \(end\)\?raw %}' "$here/../../ansible/roles/monitoring-server/templates/alert-rules.yml.j2" > "$work/rules.yml"
cp "$here/alerts.test.yml" "$work/"
image="$(awk '/^prometheus_image:/ {print $2}' "$here/../../ansible/group_vars/internal.yml")"
docker run --rm -v "$work:/w" -w /w --entrypoint promtool "$image" test rules alerts.test.yml
