#!/usr/bin/env bash
# Emit Prometheus textfile metrics for each top-level directory under /srv.
# node-exporter (with --collector.textfile.directory) picks up the output and
# exposes srv_directory_used_bytes{category,name} as part of its normal scrape.
#
# Atomic write via tmpfile+rename so node-exporter never reads a half-written file.

set -euo pipefail

OUTPUT_DIR="/var/lib/node-exporter"
OUTPUT="${OUTPUT_DIR}/srv_disk_usage.prom"

[ -d "${OUTPUT_DIR}" ] || exit 0

TMP="$(mktemp --tmpdir="${OUTPUT_DIR}" srv_disk_usage.XXXXXX.tmp)"
trap 'rm -f "${TMP}"' EXIT

{
  echo "# HELP srv_directory_used_bytes Disk usage in bytes for top-level directories under /srv"
  echo "# TYPE srv_directory_used_bytes gauge"
  shopt -s nullglob
  for d in /srv/stack/* /srv/data/*; do
    [ -d "${d}" ] || continue
    size="$(du -sb "${d}" 2>/dev/null | awk '{print $1}')"
    [ -n "${size:-}" ] || continue
    category="$(awk -F/ '{print $3}' <<< "${d}")"
    name="$(basename "${d}")"
    printf 'srv_directory_used_bytes{category="%s",name="%s",path="%s"} %s\n' \
      "${category}" "${name}" "${d}" "${size}"
  done
} > "${TMP}"

mv "${TMP}" "${OUTPUT}"
trap - EXIT
