#!/usr/bin/env bash
# Collect one Markdown health report for the Hero2 fleet from the operator's machine.
# Read-only: Alertmanager/Prometheus/Grafana/Loki on the internal VM, docker/resolver/disk
# state on every VM, GitHub Actions and Xcode Cloud results. Intended for the nightly
# routine so interpretation, not collection, is what needs attention.
#
# Usage: nightly-ops-check.sh [-o report.md]   (SSH aliases: prod-deploy-contabo,
# staging-deploy-contabo, internal-deploy-contabo; `gh` authenticated for HERO2-ORG)

set -uo pipefail

OUT=""
while getopts "o:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    *) echo "usage: $0 [-o report.md]" >&2; exit 2 ;;
  esac
done

INTERNAL=internal-deploy-contabo
HOSTS=(prod-deploy-contabo staging-deploy-contabo internal-deploy-contabo)
REPOS=(backend hero2-app internal-system infrastructure trip-inference website partnerwebsite)
ORG=HERO2-ORG
SSH=(ssh -o ConnectTimeout=20 -o BatchMode=yes)
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SINCE_24H="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

prom() {  # prom "<expr>" -> rows "labels<TAB>value"
  "${SSH[@]}" "$INTERNAL" "docker exec monitoring-prometheus-1 wget -qO- 'http://localhost:9090/api/v1/query?query=$(urlenc "$1")'" 2>/dev/null \
    | jq -r '.data.result[]? | [(.metric | del(.__name__, .job) | to_entries | map("\(.key)=\(.value)") | join(" ")), .value[1]] | @tsv'
}

loki() {  # loki "<logql>" -> rows "labels<TAB>value"
  "${SSH[@]}" "$INTERNAL" "docker exec monitoring-loki-1 wget -qO- 'http://localhost:3100/loki/api/v1/query?query=$(urlenc "$1")'" 2>/dev/null \
    | jq -r '.data.result[]? | [(.metric | to_entries | map("\(.key)=\(.value)") | join(" ")), .value[1]] | @tsv'
}

section() { printf '\n## %s\n\n' "$1"; }
rows_or_none() { local rows; rows="$(cat)"; if [ -n "$rows" ]; then printf '%s\n' "$rows" | sed 's/^/- /'; else echo "- none"; fi; }

report() {
  echo "# Hero2 nightly ops check ($NOW_UTC)"

  section "Active alerts (Alertmanager)"
  "${SSH[@]}" "$INTERNAL" "docker exec monitoring-alertmanager-1 wget -qO- http://localhost:9093/api/v2/alerts" 2>/dev/null \
    | jq -r '.[]? | "\(.labels.alertname) [\(.labels.env // "-")] since \(.startsAt): \(.annotations.description // .annotations.summary // "")"' | rows_or_none

  section "Prometheus signals"
  echo "### Probes failing"; prom 'probe_success{job=~"blackbox_.*"} == 0' | rows_or_none
  echo "### Host DNS lookups failing"; prom 'hero2_dns_lookup_success == 0' | rows_or_none
  echo "### Containers restart-looping (starts in 30m > 3)"; prom 'count by (name, env) (last_over_time(container_start_time_seconds{name!=""}[30m])) > 3' | rows_or_none
  echo "### BullMQ failed sets"; prom 'redis_key_size{job="redis_bullmq",key=~"bull:.*:failed"} > 0' | rows_or_none
  echo "### Scrape targets down"; prom 'up == 0' | rows_or_none
  echo "### Root disk usage (%)"; prom '100 * (1 - node_filesystem_avail_bytes{fstype!="tmpfs",mountpoint="/"} / node_filesystem_size_bytes{fstype!="tmpfs",mountpoint="/"})' | rows_or_none

  section "Grafana log alert rules"
  "${SSH[@]}" "$INTERNAL" "docker exec monitoring-grafana-1 sh -c 'curl -s -u admin:\$GF_SECURITY_ADMIN_PASSWORD http://localhost:3000/api/prometheus/grafana/api/v1/rules'" 2>/dev/null \
    | jq -r '.data.groups[]?.rules[]? | "\(.name): state=\(.state) health=\(.health)\(if .lastError then " lastError=" + .lastError else "" end)"' | rows_or_none

  section "Logs (Loki)"
  echo "### Lines per env, last 24h"; loki 'sum by (env) (count_over_time({env=~"staging|production"}[24h]))' | rows_or_none
  echo "### Lines per env, last 15m (0 or missing = pipeline dead)"; loki 'sum by (env) (count_over_time({env=~"staging|production"}[15m]))' | rows_or_none
  # Report every line carrying an errorType and let the level be a column. Requiring
  # level=~"error|50" as well hid a real fault for as long as it has been happening:
  # syncTripToFact logs its Prisma failures at warn, so 13 dropped trip-fact writes
  # were reported as "none" while production silently lost them.
  echo "### Backend-origin error types, last 24h"; loki 'sum by (errorType, level, env) (count_over_time({env=~"staging|production", source!="flutter"} | json errorType | errorType != "" [24h]))' | rows_or_none
  # Nothing logs HTTP status today: the backend has no request logger and Traefik's
  # access log is off, so res_statusCode is absent from every line and this check can
  # only ever print "none". Say that rather than implying a clean bill of health.
  echo "### Backend HTTP 5xx responses, last 24h"
  if [ -z "$(loki 'sum(count_over_time({env=~"staging|production", service="backend"} | json | res_statusCode != "" [24h]))')" ]; then
    echo "- NO DATA SOURCE: no backend log line carries res_statusCode (HTTP request logging is disabled), so this check cannot see 5xx at all"
  else
    loki 'sum by (env) (count_over_time({env=~"staging|production", service="backend"} | json | res_statusCode >= 500 [24h]))' | rows_or_none
  fi
  echo "### Keycloak identity-provider login errors, last 24h"; loki 'sum by (env) (count_over_time({env=~"staging|production", container="hero2_keycloak"} |= "IDENTITY_PROVIDER_LOGIN_ERROR" [24h]))' | rows_or_none

  section "Hosts"
  for h in "${HOSTS[@]}"; do
    echo "### $h"
    "${SSH[@]}" "$h" '
      echo "- resolver: $(resolvectl status 2>/dev/null | grep -m1 "Current DNS Server" | sed "s/^ *//") | auth.hero2.org -> $(getent hosts auth.hero2.org | awk "{print \$1}" || echo FAIL)"
      echo "- disk /: $(df -h / | awk "NR==2{print \$5\" used, \"\$4\" free\"}")"
      echo "- failed units: $(systemctl --failed --no-legend --plain 2>/dev/null | awk "{print \$1}" | paste -sd, - | sed "s/^$/none/")"
      echo "- containers not healthy/up or restarted:"
      docker ps -a --format "{{.Names}}\t{{.Status}}" | while IFS=$'"'"'\t'"'"' read -r name status; do
        restarts=$(docker inspect --format "{{.RestartCount}}" "$name" 2>/dev/null)
        case "$status" in Up*) up=1 ;; *) up=0 ;; esac
        if [ "$up" = 0 ] || [ "${restarts:-0}" != 0 ] || echo "$status" | grep -q unhealthy; then echo "  - $name: $status (restarts=$restarts)"; fi
      done
      ' 2>/dev/null || echo "- (unreachable)"
  done

  section "GitHub Actions failures, last 24h"
  for r in "${REPOS[@]}"; do
    gh run list -R "$ORG/$r" --limit 20 --json name,conclusion,headBranch,createdAt,url 2>/dev/null \
      | jq -r --arg since "$SINCE_24H" --arg repo "$r" '.[] | select(.conclusion == "failure" and .createdAt > $since) | "\($repo): \(.name) on \(.headBranch) (\(.createdAt)) \(.url)"'
  done | rows_or_none

  section "Xcode Cloud check runs on hero2-app heads"
  # A branch head carries GitHub Actions and Xcode Cloud checks alike, so without the
  # app filter the Actions jobs reported above reappear here under the Xcode Cloud
  # heading and read as archive failures. Xcode Cloud reports a failed build as
  # action_required, which the conclusion filter below keeps.
  for b in staging production; do
    sha="$(gh api "repos/$ORG/hero2-app/commits/$b" --jq .sha 2>/dev/null)"
    [ -n "$sha" ] || { echo "- $b: (unreadable)"; continue; }
    gh api "repos/$ORG/hero2-app/commits/$sha/check-runs" --jq ".check_runs[] | select(.app.slug == \"xcode-cloud\") | \"$b \(.name): \(.conclusion // .status)\"" 2>/dev/null \
      | grep -vE ": (success|skipped)$" | sed 's/^/- /' || true
  done | { rows="$(cat)"; if [ -n "$rows" ]; then printf '%s\n' "$rows"; else echo "- all successful"; fi; }
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  report | tee "$OUT"
else
  report
fi
