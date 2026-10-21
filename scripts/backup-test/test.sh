#!/usr/bin/env bash
# Local end-to-end test of the backup roles' scripts against real containers:
# an append-only rest-server, the two Postgres services a backend VM runs, and
# a stand-in MinIO directory. Usage: scripts/backup-test/test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
roles="$here/../../ansible/roles"
net=hero2-backup-test
pass=0
fail=0
log="$(mktemp)"
# Steps write their output to $log; a failing check prints it.
check() {
  if [ "$2" = 0 ]; then
    pass=$((pass + 1)); echo "PASS  $1"
  else
    fail=$((fail + 1)); echo "FAIL  $1"; sed 's/^/      /' "$log" | tail -30
  fi
}
cleanup() {
  docker rm -f hbt-rest hbt-runner hbt-pg hbt-kc hero2-restore-staging >/dev/null 2>&1 || true
  docker volume rm -f hbt-repos hbt-tls hbt-metrics hbt-minio >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap 'cleanup; rm -f "$log"' EXIT
cleanup

docker build -q -t hero2-backup-runner "$here" >/dev/null
docker network create "$net" >/dev/null
for v in hbt-repos hbt-tls hbt-metrics hbt-minio; do docker volume create "$v" >/dev/null; done

# Two Postgres services labelled the way compose labels them on the VMs, under
# their own project so a local dev stack never matches.
for svc in postgres:hbt-pg keycloak-db:hbt-kc; do
  docker run -d --name "${svc#*:}" --network "$net" \
    --label com.docker.compose.project=hbt --label "com.docker.compose.service=${svc%%:*}" \
    -e POSTGRES_USER=hero2 -e POSTGRES_PASSWORD=x -e POSTGRES_DB=hero2 postgres:17 >/dev/null
done
for c in hbt-pg hbt-kc; do
  until docker exec "$c" pg_isready -h 127.0.0.1 -U hero2 -d hero2 >/dev/null 2>&1; do sleep 1; done
  docker exec "$c" psql -U hero2 -d hero2 -qc 'create table "AuthUser" (id int); insert into "AuthUser" values (1);'
done

# The server half: certificate, htpasswd and rest-server, as the backup-server role sets them up.
docker run --rm -v hbt-tls:/tls -v "$roles/backup-server/files:/role:ro" hero2-backup-runner \
  sh -c 'apt-get -qq update >/dev/null && apt-get -qq install -y openssl apache2-utils >/dev/null &&
         openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=hero2-backup" \
           -addext "subjectAltName=DNS:hbt-rest" -keyout /tls/rest-server.key -out /tls/rest-server.crt 2>/dev/null &&
         htpasswd -bBc /tls/.htpasswd staging pw-staging 2>/dev/null'
docker run -d --name hbt-rest --network "$net" -v hbt-repos:/data -v hbt-tls:/tls:ro \
  restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5 \
  rest-server --path /data --listen :8000 --append-only --private-repos \
  --tls --tls-cert /tls/rest-server.crt --tls-key /tls/rest-server.key --htpasswd-file /tls/.htpasswd >/dev/null

runner() {
  # A fixed hostname, like a VM across nights, so runs share snapshot groups.
  docker run --rm --network "$net" --hostname staging-vm -v /var/run/docker.sock:/var/run/docker.sock \
    -v hbt-tls:/tls:ro -v hbt-metrics:/metrics -v hbt-minio:/minio -v hbt-repos:/repos \
    -v "$roles:/roles:ro" \
    -e RESTIC_REPOSITORY=rest:https://staging:pw-staging@hbt-rest:8000/staging/ \
    -e RESTIC_PASSWORD=repo-pw -e RESTIC_CACERT=/tls/rest-server.crt -e BACKUP_ENV=staging -e BACKUP_COMPOSE_PROJECT=hbt \
    -e BACKUP_MINIO_DIR=/minio -e BACKUP_METRICS_DIR=/metrics \
    -e BACKUP_REPO_BASE=/repos -e RESTIC_PASSWORD_STAGING=repo-pw -e BACKUP_ENVS=staging \
    hero2-backup-runner bash -c "$1"
}
metric() { runner "cat /metrics/$1 2>/dev/null" | awk -v m="$2" '$1 ~ "^"m"[{ ]" {print $2}'; }

runner 'shellcheck /roles/backup-client/files/hero2-backup.sh /roles/backup-server/files/hero2-backup-maintain.sh'
check "shellcheck is clean" $?
runner 'echo photo > /minio/logo.png'

runner /roles/backup-client/files/hero2-backup.sh >"$log" 2>&1; check "first run initializes the repository and backs up" $?
first="$(metric hero2_backup.prom hero2_backup_last_success_timestamp_seconds)"
[ -n "$first" ]; check "first run records a success time" $?
sleep 1
runner /roles/backup-client/files/hero2-backup.sh >"$log" 2>&1; check "second run reuses the repository" $?
second="$(metric hero2_backup.prom hero2_backup_last_success_timestamp_seconds)"
[ -n "$second" ] && [ "$second" -gt "$first" ]; check "second run moves the success time forward" $?
count="$(runner 'restic snapshots --json' | grep -o '"short_id"' | wc -l | tr -d ' ')"
[ "$count" = 6 ]; check "each run stores three snapshots (got $count)" $?

runner 'restic forget --keep-last 1 --prune' >/dev/null 2>&1 && rc=1 || rc=0
check "a backup client cannot delete snapshots" $rc

docker stop hbt-pg >/dev/null
runner /roles/backup-client/files/hero2-backup.sh >/dev/null 2>&1 && rc=1 || rc=0
check "a run with the database down fails" $rc
[ "$(metric hero2_backup.prom hero2_backup_last_run_success)" = 0 ]; check "the failed run is reported" $?
[ "$(metric hero2_backup.prom hero2_backup_last_success_timestamp_seconds)" = "$second" ]; check "the failed run keeps the last success time" $?
docker start hbt-pg >/dev/null

runner /roles/backup-server/files/hero2-backup-maintain.sh >"$log" 2>&1; check "maintenance run succeeds" $?
[ "$(metric hero2_backup_restore_staging.prom hero2_backup_restore_test_success)" = 1 ]; check "the restore test loads the dump and finds the users" $?

# systemd starts the unit without HOME; restic then cannot open its cache and
# fails every command, which must not read as forged snapshots.
runner 'env -u HOME -u XDG_CACHE_HOME /roles/backup-server/files/hero2-backup-maintain.sh' >"$log" 2>&1 && rc=1 || rc=0
check "a run where restic cannot start fails" $rc
[ "$(metric hero2_backup_prune_staging.prom hero2_backup_suspect_snapshots)" = 0 ]; check "a failed listing is not reported as forged snapshots" $?
[ "$(metric hero2_backup_prune_staging.prom hero2_backup_prune_success)" = 0 ]; check "the failed listing is reported as a failed prune" $?

# A compromised app VM holds the repository password and can add snapshots
# stamped with any time; backdated ones would survive the next prune in place
# of the real history.
runner 'restic backup --tag postgres --stdin --stdin-filename postgres.dump --time "2026-01-01 00:00:00" < /etc/hostname' >/dev/null 2>&1
before="$(runner 'restic snapshots --json' | grep -o '"short_id"' | wc -l | tr -d ' ')"
runner /roles/backup-server/files/hero2-backup-maintain.sh >"$log" 2>&1 && rc=1 || rc=0
check "a snapshot stamped with a false time stops the prune" $rc
after="$(runner 'restic snapshots --json' | grep -o '"short_id"' | wc -l | tr -d ' ')"
[ "$before" = "$after" ]; check "nothing is pruned from a repository with forged snapshots ($before -> $after)" $?
[ "$(metric hero2_backup_prune_staging.prom hero2_backup_suspect_snapshots)" = 1 ]; check "the forged snapshot is reported" $?
[ "$(metric hero2_backup_prune_staging.prom hero2_backup_prune_success)" = 0 ]; check "the skipped prune is reported" $?

runner 'pack=$(find /repos/staging/data -type f | head -1); printf garbage > "$pack"'
BACKUP_FORCE_CHECK=1 runner 'BACKUP_FORCE_CHECK=1 /roles/backup-server/files/hero2-backup-maintain.sh' >"$log" 2>&1 && rc=1 || rc=0
check "a damaged repository fails maintenance" $rc
[ "$(metric hero2_backup_check_staging.prom hero2_backup_check_success)" = 0 ]; check "the damaged repository is reported" $?

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
