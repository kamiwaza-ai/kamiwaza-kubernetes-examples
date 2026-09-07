# Administrator-owned development registry

Deploy a small authenticated OCI registry for isolated development clusters.

**Tags:** #operator #registry #development #storage

This registry is external substrate. It has no `KamiwazaPlatform` owner reference, is not installed by the operator chart, and is not a production default. The cluster administrator owns its credentials, PVC, upgrades, backup, and deletion. The scenario uses the dedicated `kamiwaza-examples` namespace.

## Prerequisites

- The `kamiwaza-examples` namespace exists.
- A dynamic RWO StorageClass and at least `100Gi` of capacity.
- Access to the release-pinned registry image.
- `htpasswd` for the lab credential procedure below.

Copy the manifest and replace `example-rwo` with the approved StorageClass:

```bash
cp registry.yaml registry.local.yaml
sed -i "s/example-rwo/${KAMIWAZA_STORAGE_CLASS:?Set KAMIWAZA_STORAGE_CLASS}/g" \
  registry.local.yaml
```

## Create credentials without committing them

For production, project credentials from the approved secret authority. For an isolated lab, create temporary mode-`0600` files and let `kubectl` encode them:

```bash
export REGISTRY_USERNAME=kamiwaza
CREDENTIAL_DIR="$(mktemp -d)"
chmod 0700 "${CREDENTIAL_DIR}"
trap 'rm -rf "${CREDENTIAL_DIR}"; unset REGISTRY_PASSWORD' EXIT

read -rsp 'Registry password: ' REGISTRY_PASSWORD
echo
printf '%s' "${REGISTRY_USERNAME}" >"${CREDENTIAL_DIR}/username"
printf '%s' "${REGISTRY_PASSWORD}" >"${CREDENTIAL_DIR}/password"
printf '%s\n' "${REGISTRY_PASSWORD}" | \
  htpasswd -cBin "${CREDENTIAL_DIR}/htpasswd" "${REGISTRY_USERNAME}"

kubectl -n kamiwaza-examples create secret generic registry-htpasswd \
  --from-file=htpasswd="${CREDENTIAL_DIR}/htpasswd" \
  --dry-run=client -o yaml | kubectl apply --server-side -f -

kubectl -n kamiwaza-examples create secret generic kamiwaza-registry-credentials \
  --from-file=username="${CREDENTIAL_DIR}/username" \
  --from-file=password="${CREDENTIAL_DIR}/password" \
  --dry-run=client -o yaml | kubectl apply --server-side -f -

rm -rf "${CREDENTIAL_DIR}"
unset REGISTRY_PASSWORD
trap - EXIT
```

The first Secret configures the registry. The second is the target-local credential reference named by immutable admin policy. The operator references it but never owns or mutates its data.

## Preview and apply

```bash
kubectl diff --server-side -f registry.local.yaml
kubectl apply --server-side \
  --field-manager=kamiwaza-registry-admin \
  -f registry.local.yaml
```

## Verify

In one terminal:

```bash
kubectl -n kamiwaza-examples rollout status deployment/registry --timeout=5m
kubectl -n kamiwaza-examples get service registry
kubectl -n kamiwaza-examples get pvc registry-data
kubectl -n kamiwaza-examples port-forward service/registry 5000:5000
```

From another terminal, the unauthenticated probe should return HTTP `401`:

```bash
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  http://127.0.0.1:5000/v2/
```

That response proves transport reachability but not credentials. Perform an authenticated push/pull with the approved client before using the registry for model artifacts.

## Connect immutable policy

The default operator values expect:

```yaml
adminPolicy:
  modelRegistry:
    type: OCIRegistry
    endpoint: registry.kamiwaza-examples.svc.cluster.local:5000
    credentialSecretName: kamiwaza-registry-credentials
    usernameKey: username
    passwordKey: password
```

Keep this endpoint and Secret local to the target namespace. Do not embed credentials in the endpoint, chart values, custom resource, or repository.

## Cleanup

Remove the Deployment, Service, ConfigMap, and ServiceAccount only when no platform uses the registry. PVC and Secret deletion are separate administrator decisions:

```bash
kubectl -n kamiwaza-examples delete --ignore-not-found \
  deployment/registry service/registry configmap/registry-config serviceaccount/registry
```

Review and delete `registry-data`, `registry-htpasswd`, and `kamiwaza-registry-credentials` only under the approved data-retention procedure.
