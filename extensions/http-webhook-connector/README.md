# HTTP webhook connector

## Purpose

Receive a signed webhook, queue it durably, deliver it to a bounded receiver, and prove duplicate requests create one accepted result. `ExtensionRuntime` and `Extension` replace the deprecated `KamiwazaExtension` shape: administrator runtime policy and owner package intent now have separate RBAC boundaries.

## Grounded design

Connector behavior lives in a SHA-256-verified artifact. Tenant intent cannot redefine images, routes, service graphs, storage classes, or platform identity.

## Prerequisites

- Shared manager installed through the [operator quickstart](../../operator/quickstart/) with this scenario's `operator-values.yaml` applied as administrator policy.
- Dynamic `example-rwo` StorageClass, administrator Gateway for `webhook.example.invalid`, Gateway namespace `gateway-system`, and TLS Secret `kamiwaza-gateway-tls`.
- Existing Secret `webhook-signing` with key `WEBHOOK_SECRET`; never commit its value.
- Published trust bundle plus the administrator-owned enforcing proxy and conformance evidence named in values. The operator does not install that proxy.

`extension.yaml` carries ConfigMap `extension-bundle-349be8c9080a`. Its exact `bundle.yaml` bytes hash to `sha256:349be8c9080ad4da77fc089aa40840fa9fdd9795f9fbdf08ed3bf9e0948ca00f`. Changing one byte requires a new digest and ConfigMap name.

## Apply and verify

```bash
kubectl diff --server-side --field-manager=extension-owner -k .
kubectl apply --server-side --field-manager=extension-owner -k .
kubectl -n kw-webhook wait --for=condition=Ready extension/webhook-connector --timeout=15m
kubectl -n kw-webhook logs job/webhook-check
```

Expected result is `accepted: 1` for `example-event-001` after two signed submissions. The connector stores accepted work before delivery, uses bounded jittered retry during receiver outage, and never logs body or signature.

To prove outage recovery, apply `receiver-unavailable.yaml`, submit a unique signed event, confirm `/hooks/healthz` reports one queued event, then reapply `receiver.yaml`. Delivery must complete without creating a second accepted key. These are desired-state changes; do not delete generated pods.

## Current API boundaries

The clean extension artifact supports ports, dependencies, routes, resources, and durable/scratch volumes. It does not expose arbitrary health-probe or per-extension egress fields. Deployment availability is the current health signal, while outbound authority is administrator policy for the closed `ExtensionExternalAPI` consumer class. This scenario therefore validates that those platform-level controls remain effective rather than reintroducing the deprecated tenant-owned network surface.

## Cleanup

```bash
kubectl -n kw-webhook delete job/webhook-check extension/webhook-connector extensionruntime/webhooks deployment/webhook-receiver service/webhook-receiver
kubectl -n kw-webhook get pvc
```

Review `webhook-results` and the extension state PVC before deleting either. Gateway, proxy, trust, and Secret prerequisites remain external.
