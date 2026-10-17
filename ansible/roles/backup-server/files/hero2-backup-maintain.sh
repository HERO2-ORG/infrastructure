#!/usr/bin/env bash
# Daily upkeep of the environments' restic repositories, run on the internal VM
# against the files rest-server stores (append-only only binds HTTP clients):
# prune to the retention policy, check the data weekly, and restore the app
# database into a throwaway Postgres weekly (daily while it is failing) to
# prove the dump is usable.
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
    echo "hero2_backup_$1{backup_env=\"${env}\"} $2" >> "$tmp"
    shift 2
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$file"
}

# Snapshots whose stated time is more than an hour from when rest-server wrote
# them, or in the future. A client with the repository password can stamp any
# time; backdated snapshots would outlive the real ones in the next prune.
suspect_snapshots() {
  restic snapshots --json | python3 -c '
import datetime, json, os, re, sys
repo, now = sys.argv[1], datetime.datetime.now(datetime.timezone.utc).timestamp()
for snap in json.load(sys.stdin):
    stated = datetime.datetime.fromisoformat(re.sub(r"(\.\d{6})\d*", r"\1", snap["time"])).timestamp()
    received = os.path.getmtime(os.path.join(repo, "snapshots", snap["id"]))
    if abs(stated - received) > 3600 or stated > now + 3600:
        print(snap["short_id"])
' "$RESTIC_REPOSITORY"
}

restore_test() {
  local env="$1" dir name count waited=0
  dir="$(mktemp -d)"
  name="hero2-restore-${env}"
  trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$dir"' RETURN
  restic dump latest --tag postgres postgres.dump > "${dir}/app.dump" || return 1
  # A run killed mid-test leaves its container, holding a copy of the data.
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=restore-test postgres:17 >/dev/null || return 1
  # Over TCP: the image's first-start setup server listens only on the socket,
  # so a socket check can pass just before that server shuts down again.
  until docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
    if [ "$waited" -ge 120 ]; then
      echo "restore test: Postgres was not ready after ${waited}s" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  docker exec -i "$name" pg_restore -U postgres -d postgres --no-owner < "${dir}/app.dump" || return 1
  count="$(docker exec "$name" psql -U postgres -tAc 'select count(*) from "AuthUser"')" || return 1
  [ "$count" -ge 1 ]
}

last_value() {  # last_value <file> <name>
  awk -v m="hero2_backup_$2" '$1 ~ "^"m"[{]" {print $2}' "${metrics_dir}/hero2_backup_$1.prom" 2>/dev/null
}

for env in ${BACKUP_ENVS:-staging production}; do
  export RESTIC_REPOSITORY="${repo_base}/${env}"
  password_var="RESTIC_PASSWORD_$(echo "$env" | tr '[:lower:]' '[:upper:]')"
  export RESTIC_PASSWORD="${!password_var:?}"

  # A listing that fails says nothing about tampering; it still blocks the
  # prune, and BackupUpkeepFailing reports it.
  suspect_count=0
  if ! suspects="$(suspect_snapshots)"; then
    echo "${env}: not pruning, could not list the snapshots" >&2
    ok=0
  elif suspect_count="$(echo "$suspects" | grep -c . || true)"; [ "$suspect_count" -gt 0 ]; then
    echo "${env}: not pruning, snapshots with a false time: ${suspects}" >&2
    ok=0
  elif restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then
    ok=1
  else
    ok=0
  fi
  [ "$ok" = 1 ] || failed=1
  snapshots="$(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l)"
  metric "prune" "$env" prune_success "$ok" prune_timestamp_seconds "$(date +%s)" \
    snapshot_count "$snapshots" suspect_snapshots "$suspect_count"

  if [ "$weekly" = 1 ]; then
    if restic check --read-data-subset=10%; then ok=1; else ok=0; failed=1; fi
    metric check "$env" check_success "$ok" check_timestamp_seconds "$(date +%s)"
  fi

  if [ "$weekly" = 1 ] || [ "$(last_value "restore_${env}" restore_test_success)" != 1 ]; then
    if restore_test "$env"; then ok=1; else ok=0; failed=1; fi
    metric restore "$env" restore_test_success "$ok" restore_test_timestamp_seconds "$(date +%s)"
  fi
done

exit "$failed"
