#!/usr/bin/env bash
# Resolve each name given as an argument through the host resolver, the same path
# Docker's embedded DNS forwards container lookups to (127.0.0.11 -> 127.0.0.53), and
# emit hero2_dns_lookup_success{name} / hero2_dns_lookup_seconds{name} for node-exporter.
# A 0 here means every container on this host is failing the same lookup.
#
# Atomic write via tmpfile+rename so node-exporter never reads a half-written file.

set -uo pipefail

OUTPUT_DIR="/var/lib/node-exporter"
OUTPUT="${OUTPUT_DIR}/hero2_dns_check.prom"

[ -d "${OUTPUT_DIR}" ] || exit 0

TMP="$(mktemp --tmpdir="${OUTPUT_DIR}" hero2_dns_check.XXXXXX.tmp)"
trap 'rm -f "${TMP}"' EXIT

{
  echo "# HELP hero2_dns_lookup_success 1 when the host resolver answered for the name, 0 otherwise"
  echo "# TYPE hero2_dns_lookup_success gauge"
  echo "# HELP hero2_dns_lookup_seconds Wall-clock seconds the lookup took"
  echo "# TYPE hero2_dns_lookup_seconds gauge"
  for name in "$@"; do
    start="$(date +%s.%N)"
    if timeout 5 getent hosts "${name}" >/dev/null 2>&1; then ok=1; else ok=0; fi
    seconds="$(awk -v a="${start}" -v b="$(date +%s.%N)" 'BEGIN { printf "%.3f", b - a }')"
    printf 'hero2_dns_lookup_success{name="%s"} %s\n' "${name}" "${ok}"
    printf 'hero2_dns_lookup_seconds{name="%s"} %s\n' "${name}" "${seconds}"
  done
} > "${TMP}"

chmod 0644 "${TMP}"
mv "${TMP}" "${OUTPUT}"
trap - EXIT
