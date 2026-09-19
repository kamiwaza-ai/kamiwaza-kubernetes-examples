# Independent extension lifecycle

Apply a `KamiwazaExtension` through the extension controller in the shared manager.

**Tags:** #operator #extensions #shared-manager #network-policy

## Prerequisites

- The shared manager is installed and watches `kamiwaza-examples`.
- Immutable policy enables extensions in `kamiwaza-examples`.
- The image repository and digest are approved by immutable image policy and accessible through an installed pull Secret.

The checked-in manifest mirrors the operator's release-verification extension sample. Before use against another release, replace the image tag and digest together with the values published for that release. Platform addresses and trust settings are derived from the `KamiwazaPlatform`; the extension does not restate or weaken them.

## Apply

```bash
kubectl diff --server-side --field-manager=platform-operator-user -f kamiwaza-extension.yaml
kubectl apply --server-side \
  --field-manager=platform-operator-user \
  -f kamiwaza-extension.yaml
```

The extension is an independent aggregate root. Its controller alone owns extension status, finalizers, and derived workloads. Applying it must not roll platform workloads or change `KamiwazaPlatform` status.

## Observe

```bash
kubectl -n kamiwaza-examples get kamiwazaextensions.extensions.kamiwaza.ai example-web
kubectl -n kamiwaza-examples describe kamiwazaextensions.extensions.kamiwaza.ai example-web
kubectl -n kamiwaza-examples wait \
  --for=condition=Ready \
  kamiwazaextensions.extensions.kamiwaza.ai/example-web \
  --timeout=10m
```

If policy denies the image, namespace, risk tier, ingress mode, or another requested capability, correct the manifest or immutable administrator policy. Do not add permissions to the shared manager ad hoc.

Inspect extension-owned children using the stable instance label:

```bash
kubectl -n kamiwaza-examples get deployment,service,networkpolicy \
  -l app.kubernetes.io/instance=example-web
```

## Verify root isolation

Record the platform identity and generation, delete the extension, and verify that the independent platform root remains Ready:

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,GENERATION:.metadata.generation

kubectl -n kamiwaza-examples delete kamiwazaextension.extensions.kamiwaza.ai example-web

kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,GENERATION:.metadata.generation
kubectl -n kamiwaza-examples wait \
  --for=condition=Ready \
  kamiwazaplatform.platform.kamiwaza.ai/kamiwaza \
  --timeout=10m
kubectl -n kamiwaza-examples get deployment,service,networkpolicy,httproute \
  -l app.kubernetes.io/instance=example-web
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.ai
```

The platform UID and generation must remain unchanged. The final child query must return no extension-owned resources. Deleting the extension does not delete the platform or subordinate model resources.
