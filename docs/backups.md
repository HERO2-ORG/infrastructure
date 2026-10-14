# Backups

Every night each app VM (staging, production) backs up the app database, the Keycloak database and the MinIO photo store to the internal VM, encrypted with restic. Snapshots are kept for 7 days, 4 weeks and 6 months.

| What | Where |
| --- | --- |
| Nightly backup | `hero2-backup.timer` on each app VM, 03:15 UTC plus up to 20 minutes |
| Repositories | `/srv/data/backups/<env>` on the internal VM, served by an append-only rest-server on port 8000 |
| Upkeep | `hero2-backup-maintain.timer` on the internal VM, 05:30 UTC: prune daily; data check and a restore of the app database into a throwaway Postgres on Sundays |
| Alerts | `BackupMissing`, `BackupNeverReported`, `BackupFailed`, `BackupUnusable` |
| Secrets | `RESTIC_PASSWORD_<ENV>` (encryption), `RESTIC_REST_PASSWORD_<ENV>` (server login), `BACKUP_TLS_BUNDLE`, in `ansible/secrets.yml.enc` |

The app VMs can add snapshots but cannot delete them, so a compromised app VM cannot destroy its own backups. Losing a `RESTIC_PASSWORD_<ENV>` makes that environment's backups unreadable; the vault is the only copy.

## Restore

Run these as root on the internal VM, where the repositories are local files.

```bash
set -a; . /etc/hero2-backup/maintain.env; set +a
export RESTIC_REPOSITORY=/srv/data/backups/production RESTIC_PASSWORD="$RESTIC_PASSWORD_PRODUCTION"
restic snapshots
```

### One database

```bash
restic dump latest --tag postgres postgres.dump > /tmp/app.dump        # or --tag keycloak-db keycloak-db.dump
scp /tmp/app.dump deploy@<app vm>:/tmp/
```

On the app VM, stop the backend so nothing writes during the restore, then load the dump into a fresh database:

```bash
docker stop backend-backend-1
docker exec -i backend-postgres-1 sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner' < /tmp/app.dump
docker start backend-backend-1
```

For a snapshot other than the latest, replace `latest` with its ID from `restic snapshots`.

### The photo store

```bash
restic restore latest --tag minio --target /tmp/minio-restore
rsync -a /tmp/minio-restore/srv/stack/backend/volumes/minio/ deploy@<app vm>:/tmp/minio/
```

On the app VM, stop MinIO, replace `/srv/stack/backend/volumes/minio` with `/tmp/minio`, and start it again.

### A whole VM

Provision the VM, apply its Ansible playbook and deploy the backend so the containers exist. Then restore both databases and the photo store as above.

## Check by hand

```bash
sudo systemctl start hero2-backup.service && journalctl -u hero2-backup -n 50          # app VM
sudo systemctl start hero2-backup-maintain.service && journalctl -u hero2-backup-maintain -n 80   # internal VM
cat /var/lib/node-exporter/hero2_backup*.prom
```

## Test

`scripts/backup-test/test.sh` runs the backup and upkeep scripts against real containers (rest-server, two Postgres, a stand-in photo store), including the append-only refusal and a damaged repository. `scripts/backup-test/alerts.sh` unit-tests the alert rules with promtool.
