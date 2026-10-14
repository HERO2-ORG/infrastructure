#!/usr/bin/env bash
# Daily upkeep of the environments' restic repositories, run on the internal VM
# against the files rest-server stores (append-only only binds HTTP clients):
# prune to the retention policy, check the data weekly, and weekly restore the
# app database into a throwaway Postgres to prove the dump is usable.
# Each step writes its own metrics file, so a step that did not run today keeps
# reporting its last result.
set -uo pipefail

repo_base="${BACKUP_REPO_BASE:-/srv/data/backups}"
metrics_dir="${BACKUP_METRICS_DIR:-/var/lib/node-exporter}"
weekly=0
if [ "$(date +%u)" = 7 ] || [ -n "${BACKUP_FORCE_CHECK:-}" ]; then weekly=1; fi
failed=0

metric() {  # metric <file> <env> <name> <value>...
  local file="${metrics_dir}/hero2_backup_$1_$2.prom" env="$2" tmp
  shift 2
  tmp="$(mktemp "${metrics_dir}/hero2_backup.XXXXXX")"
  while [ $# -gt 0 ]; do
    echo "hero2_backup_$1{env=\"${env}\"} $2" >> "$tmp"
    shift 2
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$file"
}

restore_test() {
  local env="$1" dir name count
  dir="$(mktemp -d)"
  name="hero2-restore-${env}"
  trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$dir"' RETURN
  restic dump latest --tag postgres postgres.dump > "${dir}/app.dump" || return 1
  docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=restore-test postgres:17 >/dev/null || return 1
  for _ in $(seq 60); do
    docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
  sleep 2
  docker exec -i "$name" pg_restore -U postgres -d postgres --no-owner < "${dir}/app.dump" || return 1
  count="$(docker exec "$name" psql -U postgres -tAc 'select count(*) from "AuthUser"')" || return 1
  [ "$count" -ge 1 ]
}

for env in ${BACKUP_ENVS:-staging production}; do
  export RESTIC_REPOSITORY="${repo_base}/${env}"
  password_var="RESTIC_PASSWORD_$(echo "$env" | tr '[:lower:]' '[:upper:]')"
  export RESTIC_PASSWORD="${!password_var:?}"

  if restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then ok=1; else ok=0; failed=1; fi
  snapshots="$(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l)"
  metric prune "$env" prune_success "$ok" snapshot_count "$snapshots"

  if [ "$weekly" = 1 ]; then
    if restic check --read-data-subset=10%; then ok=1; else ok=0; failed=1; fi
    metric check "$env" check_success "$ok" check_timestamp_seconds "$(date +%s)"
  fi

  if [ "$weekly" = 1 ] || [ ! -f "${metrics_dir}/hero2_backup_restore_${env}.prom" ]; then
    if restore_test "$env"; then ok=1; else ok=0; failed=1; fi
    metric restore "$env" restore_test_success "$ok" restore_test_timestamp_seconds "$(date +%s)"
  fi
done

exit "$failed"
