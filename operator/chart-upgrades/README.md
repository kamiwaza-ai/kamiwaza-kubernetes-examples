# Upgrade the operator Helm release

Upgrade the shared manager chart without confusing operator lifecycle with `KamiwazaPlatform.spec.version`.

**Tags:** #operator #helm #chart-upgrade #crd

The Helm release owns operator bootstrap: CRDs on first install, one manager Deployment, ServiceAccount, immutable policy, and scope-specific RBAC. The platform custom resource owns the Kamiwaza application lifecycle. A chart upgrade does not authorize a platform version change.

## Prerequisites

- A signed target chart and exact chart version from the Kamiwaza release.
- The complete reviewed values used for the current installation, stored without Secrets.
- A current cluster context and manager namespace.
- The target release's compatibility, CRD-upgrade, and rollback notes.
- Platform status is stable unless the release procedure explicitly permits a manager upgrade during a transition.

The commands use `kamiwaza-examples-system` and `kamiwaza-examples` for an
isolated rehearsal. Replace both only after selecting the reviewed release.

## 1. Capture current state

```bash
helm status kamiwaza-platform-operator -n kamiwaza-examples-system
helm get values kamiwaza-platform-operator -n kamiwaza-examples-system -o yaml \
  >operator-values.before.yaml
kubectl -n kamiwaza-examples-system get deployment kamiwaza-platform-operator \
  -o custom-columns=IMAGE:.spec.template.spec.containers[0].image,AVAILABLE:.status.availableReplicas
kubectl get crd \
  kamiwazaplatforms.platform.kamiwaza.io \
  kamiwazaextensions.extensions.kamiwaza.io \
  modeldeployments.serving.kamiwaza.io \
  -o custom-columns=NAME:.metadata.name,STORED_VERSIONS:.status.storedVersions
```

Keep this operational evidence outside Git if it contains cluster-specific values.

## 2. Review and render the target

```bash
export OPERATOR_CHART=oci://registry.example.com/kamiwaza-platform-operator
export OPERATOR_CHART_VERSION=0.1.0 # Replace with the target release version.
read -rp "Operator image digest (sha256:...): " OPERATOR_IMAGE_DIGEST

helm show chart "${OPERATOR_CHART}" --version "${OPERATOR_CHART_VERSION}"
helm show values "${OPERATOR_CHART}" --version "${OPERATOR_CHART_VERSION}" \
  >operator-values.defaults.yaml
helm template kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --version "${OPERATOR_CHART_VERSION}" \
  --values operator-values.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  >operator-rendered.yaml
```

Review the rendered ServiceAccount, manager Deployment, policy, Roles, RoleBindings, and optional overlays. Verify the manager image uses the release-published digest. Do not use `--reuse-values` as a substitute for reconciling the target chart schema with the complete values file.

## 3. Upgrade CRDs first when APIs change

Helm installs files from `crds/` on initial installation but does not upgrade or delete existing CRDs. If the target release changes an API, run its administrator-owned CRD procedure before the chart upgrade:

```bash
KUBECONFIG="${KUBECONFIG:?Set the reviewed target context}" \
  "${OPERATOR_RELEASE_DIR}/scripts/upgrade-crds.sh"
```

Require all three CRDs to be Established with the target served and stored versions. Resolve field-ownership conflicts explicitly; never grant CRD mutation to the manager.

## 4. Upgrade atomically

```bash
helm upgrade kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --version "${OPERATOR_CHART_VERSION}" \
  --values operator-values.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  --atomic \
  --timeout=10m
```

`--atomic` waits and rolls back the Helm-managed release objects when the upgrade fails. It does not roll back CRDs or reverse application migrations.

## 5. Verify

```bash
helm status kamiwaza-platform-operator -n kamiwaza-examples-system
kubectl -n kamiwaza-examples-system rollout status \
  deployment/kamiwaza-platform-operator \
  --timeout=5m
kubectl -n kamiwaza-examples-system logs \
  deployment/kamiwaza-platform-operator \
  --since=10m
kubectl -n kamiwaza-examples get kamiwazaplatform,kamiwazaextension
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io
```

Require one manager Deployment, the expected digest-pinned image, healthy manager probes, all three controllers registered, unchanged immutable watch authority, and no unrelated platform, extension, or model rollout.

## Rollback

Use `helm history` and the target release's rollback procedure. Do not run `helm rollback` until you verify that the previous manager understands the currently stored CRD versions and that no forward-only platform migration crossed its rollback boundary. Helm release rollback alone cannot restore those states.
