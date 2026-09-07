# Fresh platform quickstart

Deploy one Kamiwaza `1.3.0` platform with a separately placed manager watching only the dedicated `kamiwaza-examples` namespace.

**Tags:** #operator #quickstart #fresh-install #namespaced

The operator is under release verification. Run this workflow on a disposable or explicitly approved cluster. It does not adopt an existing Helmfile installation.

## Prerequisites

- All [operator prerequisites](../README.md#common-prerequisites).
- A signed, version-pinned release chart or a reviewed local chart checkout pinned to a commit.
- Registry access for the operator and platform images.
- A DNS name and dynamic RWO StorageClass selected for this installation.

## 1. Set installation inputs

For a published chart, pin the chart version and manager image digest supplied with your Kamiwaza release:

```bash
export OPERATOR_CHART=oci://registry.example.com/kamiwaza-platform-operator
export OPERATOR_CHART_VERSION=0.1.0
read -rp "Operator image digest (sha256:...): " OPERATOR_IMAGE_DIGEST
export KAMIWAZA_STORAGE_CLASS=gp3-csi
export KAMIWAZA_DOMAIN=kamiwaza-examples.example.com
helm show chart "${OPERATOR_CHART}" --version "${OPERATOR_CHART_VERSION}"
```

For a reviewed local checkout, set `OPERATOR_CHART` to its chart directory and
record the checkout commit instead of using `--version`.

Copy the two checked-in inputs, then replace their lab values together:

```bash
cp operator-values.yaml operator-values.local.yaml
cp kamiwaza-platform.yaml kamiwaza-platform.local.yaml
sed -i "s/example-rwo/${KAMIWAZA_STORAGE_CLASS}/g" \
  operator-values.local.yaml kamiwaza-platform.local.yaml
sed -i "s/kamiwaza-examples.example.com/${KAMIWAZA_DOMAIN}/g" \
  operator-values.local.yaml kamiwaza-platform.local.yaml
```

Review the resulting files. The platform StorageClass and domain must be allowed by the immutable policy in `operator-values.local.yaml`.

## 2. Verify administrator-owned prerequisites

The example policy selects Istio routing and cert-manager-managed trust. The operator observes or accepts administrator attestations for these dependencies; it does not install them.

```bash
kubectl get storageclass "${KAMIWAZA_STORAGE_CLASS}"
kubectl get crd certificates.cert-manager.io
kubectl get crd bundles.trust.cert-manager.io
kubectl get crd gateways.gateway.networking.k8s.io
kubectl -n istio-system get deployment
```

If your release selects external trust or another routing adapter, change the chart policy and the matching `spec.dependencies` requirements instead of installing unused controllers.

## 3. Create namespaces and image credentials

The cluster administrator creates both dedicated example namespaces. The platform Secret remains local to `kamiwaza-examples`.

```bash
kubectl create namespace kamiwaza-examples --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kamiwaza-examples-system --dry-run=client -o yaml | kubectl apply -f -

kubectl -n kamiwaza-examples create secret generic registry-pull \
  --from-file=.dockerconfigjson="${HOME}/.docker/config.json" \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml | kubectl apply --server-side -f -
```

Do not commit the generated Secret or Docker configuration.

## 4. Install the shared manager

The Helm release namespace places the manager. `manager.watchNamespaces` grants bounded watch authority independently. Preview the rendered installation, then install atomically:

```bash
helm template kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --version "${OPERATOR_CHART_VERSION}" \
  --values operator-values.local.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  >/tmp/kamiwaza-platform-operator.yaml

helm upgrade --install kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --create-namespace \
  --version "${OPERATOR_CHART_VERSION}" \
  --values operator-values.local.yaml \
  --set-string image.digest="${OPERATOR_IMAGE_DIGEST}" \
  --atomic \
  --timeout=10m

kubectl -n kamiwaza-examples-system rollout status \
  deployment/kamiwaza-platform-operator \
  --timeout=5m
```

For a local chart directory, run `helm lint "${OPERATOR_CHART}" --values operator-values.local.yaml`, retain the manager image digest override, and omit both `--version` flags. The release installs three CRDs and one manager. Helm installs CRDs from the chart's `crds/` directory before templates, but does not upgrade or delete existing CRDs; use the release-provided CRD upgrade workflow before a chart upgrade that changes an API. Do not install a second extension or model manager.

## 5. Apply platform intent

The platform user applies the same namespaced resource regardless of manager placement. Preview the server-side apply before changing live state:

```bash
kubectl diff --server-side \
  --field-manager=platform-operator-user \
  -f kamiwaza-platform.local.yaml

kubectl apply --server-side \
  --field-manager=platform-operator-user \
  -f kamiwaza-platform.local.yaml
```

The example declares a small CPU-only model so the model path does not require a GPU. Image and model artifacts still require the registries and outbound access approved for the cluster.

## 6. Observe convergence

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza
kubectl -n kamiwaza-examples describe kamiwazaplatform kamiwaza
kubectl -n kamiwaza-examples get jobs,pods
```

A blocked platform is a result, not a signal to bypass policy. Read the stable condition reason and component status:

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
```

Correct the administrator-owned prerequisite, immutable policy, or user intent named by the condition.

## 7. Verify

```bash
./verify.sh
```

Success requires the shared manager Deployment to be available, the platform `Ready` condition to be true, `status.currentVersion` to equal `1.3.0`, and subordinate model deployments to be visible.

## Cleanup

Use the [deletion and retention](../deletion/) workflow. Do not uninstall the operator first: the platform finalizer must complete the selected retention behavior.
