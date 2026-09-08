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

The example policy selects cert-manager-managed trust and a Gateway the administrator owns. The operator observes or accepts administrator attestations for these dependencies; it does not install them. The platform resource names no ingress or mesh implementation: `spec.dependencies` covers `certManager`, `trustManager`, and `gatewayAPI` only, and routing is expressed through standard Gateway API objects, so the implementation behind the Gateway is the administrator's choice and not platform intent.

```bash
kubectl get storageclass "${KAMIWAZA_STORAGE_CLASS}"
kubectl get crd certificates.cert-manager.io
kubectl get crd bundles.trust.cert-manager.io
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get gatewayclass
```

If your release selects external trust, change the chart policy and the matching `spec.dependencies` requirements instead of installing unused controllers. Also check the controller behind your chosen GatewayClass is running, in whichever namespace it was installed.

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

Do not commit the generated Secret or Docker configuration. The platform resource carries no pull-secret field: the Secret's name is administrator policy, in `adminPolicy.images.pullSecretNames` in `operator-values.yaml`, so credential ownership is stated in one place.

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

This platform declares no model, and there is no field on the resource for one. `ModelDeployment` in `serving.kamiwaza.io` is the only surface that deploys a served model, and the platform CRD carries no model intent by design so that declaring a platform cannot deploy a model by default. A `ModelDeployment` also carries an engine-authored Pod template, which the application writes when a model is deployed through it, so this quickstart applies none by hand: a template that has never served a request would be a guess rather than an example. Image pulls still require the registries and outbound access approved for the cluster.

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

Success requires the shared manager Deployment to be available, the platform `Ready` condition to be true, and `status.currentVersion` to equal `1.3.0`. `verify.sh` also lists `ModelDeployment` objects in the namespace; on a fresh quickstart there are none, and an empty list is the expected result rather than a failure.

## Cleanup

Use the [deletion and retention](../deletion/) workflow. Do not uninstall the operator first: the platform finalizer must complete the selected retention behavior.

## How these inputs were validated

| File                                             | Validated with                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [kamiwaza-platform.yaml](kamiwaza-platform.yaml) | `kubectl apply --dry-run=server --validate=strict`, with the namespace substituted for one that exists on the validating cluster — accepted. The previous version of this file was rejected by the same command as `unknown field "spec.auth", unknown field "spec.dependencies.istio", unknown field "spec.images.pullSecrets", unknown field "spec.images.requireDigests", unknown field "spec.models", unknown field "spec.topology"`, which is why it was rewritten. |
| [operator-values.yaml](operator-values.yaml)     | `helm template` against the operator chart — renders. The policy document it produces was then loaded through the manager's own policy loader, including its cross-reference rules — accepted, with the pull-secret name and the three approved repository prefixes present. The control, the same document with `requireDigests: false`, was refused as `managed images must require digests`.                                                                          |

Every digest in `kamiwaza-platform.yaml` is copied from the operator release's own reviewed-image record. Replace them with the digests your release publishes, and never with tags.
