# Backup and restore

**Scenario:** back up and restore the two stateful Kamiwaza components — **core-postgres** (application database) and **core-etcd** (distributed key-value store). All commands run via `kubectl exec` — no client binaries required on your workstation.

**Tags:** #operations #backup #restore #postgres #etcd

## What you get

| Component | Backup method | Restore method | Data at risk without backup |
| --- | --- | --- | --- |
| **core-postgres** | `pg_dump` (logical SQL dump) | `psql` (replay SQL) | Models, deployments, configs, users, activity, contexts |
| **core-etcd** | `etcdctl snapshot save` | `etcdctl snapshot restore` | Runtime state, leader election, distributed coordination |

## Prerequisites

- Kamiwaza deployed with `core-postgres` and `core-etcd` running.
- `kubectl` configured for your cluster.

## PostgreSQL backup

### Create backup

```bash
# Dump the kamiwaza database to a local file
kubectl exec -n kamiwaza core-postgres-0 -- \
  pg_dump -U core -d kamiwaza --clean --if-exists \
  > kamiwaza-postgres-backup.sql

# Verify the dump is valid (should show CREATE TABLE statements)
head -50 kamiwaza-postgres-backup.sql
wc -l kamiwaza-postgres-backup.sql
```

### Verify backup contents

```bash
# Count tables in the dump
grep -c '^CREATE TABLE' kamiwaza-postgres-backup.sql

# Check dump size
ls -lh kamiwaza-postgres-backup.sql
```

### Restore from backup

```bash
# Copy dump into the pod and replay it
kubectl cp kamiwaza-postgres-backup.sql \
  kamiwaza/core-postgres-0:/tmp/kamiwaza-postgres-backup.sql

kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d kamiwaza -f /tmp/kamiwaza-postgres-backup.sql

# Clean up
kubectl exec -n kamiwaza core-postgres-0 -- rm /tmp/kamiwaza-postgres-backup.sql
```

### Restore to a new database (safer for validation)

```bash
# Create a temporary database, restore into it, then validate before swapping
kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d postgres -c "CREATE DATABASE kamiwaza_restore OWNER core;"

kubectl cp kamiwaza-postgres-backup.sql \
  kamiwaza/core-postgres-0:/tmp/kamiwaza-postgres-backup.sql

kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d kamiwaza_restore -f /tmp/kamiwaza-postgres-backup.sql

# Validate row counts match
kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d kamiwaza_restore -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

# Drop the test database when done
kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d postgres -c "DROP DATABASE kamiwaza_restore;"
```

## etcd backup

The etcd container is a distroless image — it has `etcdctl` but not `tar`, `cat`, or `rm`. Snapshots are saved to the data PVC (`/data`) and extracted via a lightweight helper pod.

### Create snapshot

```bash
# Save snapshot to the data PVC inside the etcd pod
kubectl exec -n kamiwaza core-etcd-0 -- \
  etcdctl snapshot save /data/backup-snapshot.db

# Extract snapshot to your workstation via a helper pod
# (needed because distroless etcd has no tar for kubectl cp)
NODE=$(kubectl get pod core-etcd-0 -n kamiwaza -o jsonpath='{.spec.nodeName}')
kubectl run etcd-backup-extract --rm -i --restart=Never \
  --image=busybox:1.36 \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"$NODE\"},
      \"containers\": [{
        \"name\": \"cp\",
        \"image\": \"busybox:1.36\",
        \"command\": [\"sh\", \"-c\", \"cat /data/backup-snapshot.db\"],
        \"stdin\": true,
        \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]
      }],
      \"volumes\": [{
        \"name\": \"data\",
        \"persistentVolumeClaim\": {\"claimName\": \"core-etcd-data-core-etcd-0\"}
      }]
    }
  }" \
  -n kamiwaza > etcd-snapshot.db

ls -lh etcd-snapshot.db

# Clean up snapshot from the data PVC
kubectl run etcd-cleanup --rm -i --restart=Never \
  --image=busybox:1.36 \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"$NODE\"},
      \"containers\": [{
        \"name\": \"rm\",
        \"image\": \"busybox:1.36\",
        \"command\": [\"rm\", \"/data/backup-snapshot.db\"],
        \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]
      }],
      \"volumes\": [{
        \"name\": \"data\",
        \"persistentVolumeClaim\": {\"claimName\": \"core-etcd-data-core-etcd-0\"}
      }]
    }
  }" \
  -n kamiwaza
```

### Verify cluster health (pre-restore check)

```bash
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl endpoint health
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl endpoint status --write-out=table
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl member list --write-out=table
```

## Automation

For production environments, wrap backup commands in a Kubernetes CronJob:

```bash
# Example: daily postgres backup at 2am (adapt the image and storage destination)
kubectl create cronjob postgres-backup \
  --namespace=kamiwaza \
  --image=bitnami/postgresql:16 \
  --schedule="0 2 * * *" \
  --dry-run=client -o yaml -- \
  sh -c 'PGPASSWORD=$PG_PASS pg_dump -h core-postgres -U core -d kamiwaza > /backup/kamiwaza-$(date +%Y%m%d).sql'
```

The CronJob YAML is a starting point — add a PVC for `/backup`, inject the password from the `core-postgres` Secret, and configure retention.

## Notes

- **pg_dump `--clean --if-exists`** generates `DROP TABLE IF EXISTS` + `CREATE TABLE` statements, making restores idempotent.
- **etcd snapshots** are point-in-time; the application may need to re-sync state after restore.
- Back up **before** upgrades, scaling operations, or any destructive maintenance.
- Store backups off-cluster (S3, NFS, local workstation) — PVC-only backups are lost if the cluster is lost.
