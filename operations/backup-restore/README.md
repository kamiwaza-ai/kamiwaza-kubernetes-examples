# Backup and restore

**Scenario:** validate PostgreSQL and etcd backups without changing live data.

Tags: #operations #backup #restore #postgres #etcd

## Safety boundary

A backup can contain credentials, tokens, user data, and model configuration.
Use encrypted storage. Limit file access to the backup operator.

PostgreSQL and etcd do not share a transaction boundary. When one recovery
point must cover both stores, stop write traffic before both backups.

Do not restore into the live PostgreSQL database or etcd PVC during validation.
A live cutover requires an approved outage and rollback runbook.

Set the platform namespace:

```bash
export PLATFORM_NAMESPACE=kamiwaza-examples
umask 077
```

## Back up PostgreSQL

Use PostgreSQL custom format. This format supports archive inspection and
fail-fast restore validation.

```bash
export POSTGRES_POD=core-postgres-0
export POSTGRES_BACKUP="kamiwaza-postgres-$(date -u +%Y%m%dT%H%M%SZ).dump"

kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  pg_dump -U core -d kamiwaza --format=custom --no-owner --no-privileges \
  > "$POSTGRES_BACKUP"

sha256sum "$POSTGRES_BACKUP" > "${POSTGRES_BACKUP}.sha256"
test -s "$POSTGRES_BACKUP"
```

### Validate the PostgreSQL restore

Restore into a temporary database. `--exit-on-error` stops at the first invalid
archive entry.

```bash
export RESTORE_DATABASE=kamiwaza_restore_validation

kubectl cp "$POSTGRES_BACKUP" \
  "$PLATFORM_NAMESPACE/$POSTGRES_POD:/tmp/kamiwaza-postgres-backup.dump"

kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  pg_restore --list /tmp/kamiwaza-postgres-backup.dump

kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  psql -U core -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $RESTORE_DATABASE OWNER core;"

kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  pg_restore -U core -d "$RESTORE_DATABASE" --exit-on-error \
  --clean --if-exists --no-owner --no-privileges \
  /tmp/kamiwaza-postgres-backup.dump
```

Compare stable application invariants in the source and restored databases.
The following query compares table and deployment counts.

```bash
kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  psql -U core -d kamiwaza -Atc \
  "SELECT current_database(),
     (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE'),
     (SELECT count(*) FROM model_deployments);"

kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  psql -U core -d "$RESTORE_DATABASE" -Atc \
  "SELECT current_database(),
     (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE'),
     (SELECT count(*) FROM model_deployments);"
```

Delete only the temporary database and copied archive after validation:

```bash
kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  psql -U core -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE $RESTORE_DATABASE;"

kubectl exec -n "$PLATFORM_NAMESPACE" "$POSTGRES_POD" -- \
  rm /tmp/kamiwaza-postgres-backup.dump
```

## Back up etcd

The etcd image is distroless. It has `etcdctl`, but it does not have `cat`,
`tar`, or the restore form of `etcdutl`.

Save the snapshot to the data PVC. Use a short-lived helper Pod to copy the
snapshot once. Do not use `kubectl run --rm -i` for binary output. An attach
fallback can duplicate the stream and corrupt the snapshot.

The helper image is pinned by digest.

```bash
export ETCD_POD=core-etcd-0
export ETCD_HELPER_IMAGE='docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
export ETCD_SNAPSHOT="kamiwaza-etcd-$(date -u +%Y%m%dT%H%M%SZ).db"
export ETCD_NODE="$(kubectl get pod -n "$PLATFORM_NAMESPACE" "$ETCD_POD" \
  -o jsonpath='{.spec.nodeName}')"
export ETCD_PVC="$(kubectl get pod -n "$PLATFORM_NAMESPACE" "$ETCD_POD" \
  -o jsonpath='{.spec.volumes[?(@.name=="core-etcd-data")].persistentVolumeClaim.claimName}')"

kubectl exec -n "$PLATFORM_NAMESPACE" "$ETCD_POD" -- \
  etcdctl snapshot save "/data/$ETCD_SNAPSHOT"

kubectl run etcd-backup-helper -n "$PLATFORM_NAMESPACE" \
  --restart=Never --image="$ETCD_HELPER_IMAGE" \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"$ETCD_NODE\"},
      \"containers\": [{
        \"name\": \"etcd-backup-helper\",
        \"image\": \"$ETCD_HELPER_IMAGE\",
        \"command\": [\"sleep\", \"600\"],
        \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]
      }],
      \"volumes\": [{
        \"name\": \"data\",
        \"persistentVolumeClaim\": {\"claimName\": \"$ETCD_PVC\"}
      }]
    }
  }"

kubectl wait -n "$PLATFORM_NAMESPACE" --for=condition=Ready \
  pod/etcd-backup-helper --timeout=60s

kubectl exec -n "$PLATFORM_NAMESPACE" etcd-backup-helper -- \
  cat "/data/$ETCD_SNAPSHOT" > "$ETCD_SNAPSHOT"

sha256sum "$ETCD_SNAPSHOT" > "${ETCD_SNAPSHOT}.sha256"
test -s "$ETCD_SNAPSHOT"

kubectl exec -n "$PLATFORM_NAMESPACE" etcd-backup-helper -- \
  rm "/data/$ETCD_SNAPSHOT"
kubectl delete pod -n "$PLATFORM_NAMESPACE" etcd-backup-helper --wait=true
```

The helper has temporary write access to the etcd PVC so it can remove the
staged snapshot. Delete the helper immediately after extraction.

### Validate the etcd restore offline

Use an OCI runtime on the workstation. The pinned etcd image includes the
`etcdutl` restore command that the deployed distroless image omits.

```bash
export ETCD_RESTORE_IMAGE='quay.io/coreos/etcd@sha256:6742378fabf521b47edd637914d508061528924d5915af0fd5d6379cfef89b7a'
export ETCD_RESTORE_DIRECTORY=etcd-restore-validation

test ! -e "$ETCD_RESTORE_DIRECTORY"

podman run --rm -v "$PWD:/backup:ro,Z" "$ETCD_RESTORE_IMAGE" \
  etcdutl snapshot status "/backup/$ETCD_SNAPSHOT" --write-out=table

mkdir "$ETCD_RESTORE_DIRECTORY"
podman run --rm -v "$PWD:/backup:Z" "$ETCD_RESTORE_IMAGE" \
  etcdutl snapshot restore "/backup/$ETCD_SNAPSHOT" \
  --data-dir="/backup/$ETCD_RESTORE_DIRECTORY"

test -f "$ETCD_RESTORE_DIRECTORY/member/snap/db"
```

This procedure proves that the archive is readable and produces an etcd data
directory. It does not replace the live data.

## Production recovery

Before a live recovery, record the platform version, image digests, backup
hashes, and recovery point. Stop all writers and stop operator reconciliation.

Restore PostgreSQL and etcd as one reviewed recovery change. Start the operator
only after both stores are ready. Then verify platform conditions, identity,
ReBAC grants, model inventory, extension inventory, and a customer smoke path.

Keep backups outside the cluster. A backup on the source PVC does not survive a
cluster or storage failure.
