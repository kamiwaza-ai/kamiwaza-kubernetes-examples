# Manager placement and namespace scope

Choose where the shared manager runs and which namespaces it can watch. Placement, watch scope, and target mutation authority are separate administrator decisions.

**Tags:** #operator #rbac #namespaces #multi-tenant

## Choose one scope

| File                         | Cache scope             | Target authorization                                                       | Use                                                                     |
| ---------------------------- | ----------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `same-namespace-values.yaml` | One namespace           | One target RoleBinding                                                     | Manager and platform share `kamiwaza-examples`                          |
| `bounded-values.yaml`        | Explicit namespace list | One target RoleBinding per listed namespace                                | Recommended for a separately managed example control namespace          |
| `all-namespaces-values.yaml` | Cluster-wide            | Non-sensitive ClusterRole plus sensitive namespaced Roles in the allowlist | Central platform team testing a reviewed cluster-wide watch requirement |

`manager.watchAnyNamespace: false` requires a non-empty `watchNamespaces` list. `manager.watchAnyNamespace: true` requires that list to be empty and still requires explicit `adminPolicy.allowedTargetNamespaces` entries.

Pin `OPERATOR_CHART_VERSION` for a repository or OCI chart reference. For a
reviewed local chart directory, record the checkout commit and omit
`--version`. Render the selected values with `helm template` before install.

Set `OPERATOR_IMAGE_DIGEST` to the release-published `sha256:` digest. Every
install below passes it with `--set-string image.digest`.

## Same-namespace manager

```bash
helm upgrade --install kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples \
  --create-namespace \
  --version "${OPERATOR_CHART_VERSION}" \
  --values same-namespace-values.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  --atomic \
  --timeout=10m
```

Platform namespace users who can modify Deployments, ServiceAccounts, Roles, RoleBindings, ConfigMaps, or Leases may also be able to alter manager authority. Use separate placement when tenant users must not administer the operator.

## Separate manager with bounded targets

The cluster administrator creates every target namespace first:

```bash
kubectl create namespace kamiwaza-examples --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kamiwaza-examples-tenant --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --create-namespace \
  --version "${OPERATOR_CHART_VERSION}" \
  --values bounded-values.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  --atomic \
  --timeout=10m
```

The chart creates one RoleBinding in each watched namespace. The manager has no wildcard or cluster-scoped target permissions in this mode.

## All-namespace watch

Use only after reviewing the expanded read authority:

```bash
helm upgrade --install kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --create-namespace \
  --version "${OPERATOR_CHART_VERSION}" \
  --values all-namespaces-values.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  --atomic \
  --timeout=10m
```

This mode uses a cluster-wide cache and a non-sensitive ClusterRole. Secret mutation remains namespaced and limited to approved targets. It is not a fallback for a missing RoleBinding in bounded mode.

## Verify the selected boundary

```bash
kubectl -n kamiwaza-examples-system get deployment,serviceaccount,role,rolebinding
kubectl -n kamiwaza-examples get role,rolebinding
kubectl auth can-i --as=system:serviceaccount:kamiwaza-examples-system:kamiwaza-platform-operator \
  get kamiwazaplatforms.platform.kamiwaza.io -n kamiwaza-examples
kubectl auth can-i --as=system:serviceaccount:kamiwaza-examples-system:kamiwaza-platform-operator \
  get nodes
kubectl auth can-i --as=system:serviceaccount:kamiwaza-examples-system:kamiwaza-platform-operator \
  create pods/exec -n kamiwaza-examples
```

For a separately placed bounded manager, the first authorization check must return `yes`; the Node and `pods/exec` checks must return `no`. Adjust the ServiceAccount namespace in these checks for same-namespace placement.

## Invariants

- One manager Deployment and one ServiceAccount run all three controllers.
- Tenant resources cannot widen the watch set, immutable policy, or RBAC overlays.
- The manager does not create Namespaces.
- Optional destructive cleanup, sandbox, host discovery, dynamic RBAC, cross-namespace resources, and SCC integration require separate administrator-installed overlays and matching immutable policy.
