# Production-secure platform

## Purpose

Declare a production-shaped platform with immutable images, existing Secret references, fail-closed authentication, platform-issued workload identity, zone-aware placement, bounded disruption, external telemetry, and retained data.

## Grounded design

Confluent's [production secure deployment](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/production-secure-deploy-auto-gen-certs) demonstrates an end-to-end secure topology. That example also stores sample credentials and private CA material beside manifests. Kamiwaza keeps the end-to-end contract but improves ownership: this directory contains no credential or certificate value, platform owners can only select administrator-approved profiles, and the operator issues workload identities without an admission webhook, node agent, or routing-provider dependency.

## Prerequisites

Replace all `example.invalid` values and `example-rwo`. Provide every exact-name Secret referenced by `platform.yaml`, plus `registry-pull` and `kamiwaza-registry-credentials`, through your secret-management system. Install a conformant Gateway API implementation and the administrator-owned Gateway named by policy. Configure the real TLS-protected `production-otel` sink. Nodes must carry `topology.kubernetes.io/zone`.

Install the reviewed operator chart with `operator-values.yaml`. Keep administrator values in a separately protected source; tenant users receive only namespaced CR permissions.

## Apply and observe

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-production-secure wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=45m
kubectl -n kw-production-secure logs job/platform-policy-check
kubectl -n kw-production-secure get kamiwazaplatform/kamiwaza -o yaml
```

Require current-generation `Ready=True`, current component conditions, ready Gateway routes, no plaintext exception, and telemetry at the approved sink. The check prints only condition reason and generation. It never reads Secrets.

## Failure behavior

Storage, Gateway, telemetry, and identity failures must name their dependency. Transient outages remain waiting and preserve data. Terminal policy errors stop until desired state changes. One dependency outage must not stop independent component convergence. Do not delete pods, remove finalizers, or patch status as recovery.

## Cleanup

```bash
kubectl -n kw-production-secure delete job/platform-policy-check kamiwazaplatform/kamiwaza
kubectl -n kw-production-secure get pvc,secret
```

`RetainData` preserves data and identity material. External Gateway, telemetry, certificate, registry, and secret-management systems remain untouched.
