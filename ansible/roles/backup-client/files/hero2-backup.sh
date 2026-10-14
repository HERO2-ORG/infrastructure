#!/usr/bin/env bash
# Nightly backup of this VM's data into its restic repository on the internal
# VM: both databases as pg_dump streams, and the MinIO photo store as files.
# Writes hero2_backup_* metrics for the textfile collector; the last success
# time only moves when every part succeeded.
set -euo pipefail

: "${BACKUP_ENV:?}"
minio_dir="${BACKUP_MINIO_DIR:-/srv/stack/backend/volumes/minio}"
metrics_dir="${BACKUP_METRICS_DIR:-/var/lib/node-exporter}"
project="${BACKUP_COMPOSE_PROJECT:-backend}"
metrics="${metrics_dir}/hero2_backup.prom"

write_metrics() {
  local ok="$1" last
  last="$(awk '$1 ~ /^hero2_backup_last_success_timestamp_seconds/ {print $2}' "$metrics" 2>/dev/null || true)"
  [ "$ok" = 1 ] && last="$(date +%s)"
  local tmp
  tmp="$(mktemp "${metrics_dir}/hero2_backup.XXXXXX")"
  {
    echo "# HELP hero2_backup_last_run_success Whether the latest nightly backup run succeeded"
    echo "# TYPE hero2_backup_last_run_success gauge"
    echo "hero2_backup_last_run_success{backup_env=\"${BACKUP_ENV}\"} ${ok}"
    if [ -n "$last" ]; then
      echo "# HELP hero2_backup_last_success_timestamp_seconds When every part of a nightly backup last succeeded"
      echo "# TYPE hero2_backup_last_success_timestamp_seconds gauge"
      echo "hero2_backup_last_success_timestamp_seconds{backup_env=\"${BACKUP_ENV}\"} ${last}"
    fi
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$metrics"
}
trap 'write_metrics 0' ERR

restic cat config >/dev/null 2>&1 || restic init

for svc in postgres keycloak-db; do
  container="$(docker ps -q --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=${svc}")"
  if [ "$(echo "$container" | grep -c .)" != 1 ]; then
    echo "expected one running ${svc} container in ${project}, found: ${container:-none}" >&2
    false
  fi
  # Uncompressed (-Z0): restic compresses the repository itself and can only
  # deduplicate what pg_dump has not already compressed.
  # shellcheck disable=SC2016 # the variables expand inside the database container
  restic backup --tag "$svc" --stdin-filename "${svc}.dump" --stdin-from-command -- \
    docker exec "$container" sh -c 'pg_dump -U "$POSTGRES_USER" -Fc -Z0 "$POSTGRES_DB"'
done

restic backup --tag minio "$minio_dir"

write_metrics 1
