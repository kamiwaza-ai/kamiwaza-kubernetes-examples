# First chat quickstart

## Purpose

Create one fresh platform and one small local `ModelDeployment`, then prove one authenticated request through the governed `/v1/chat/completions` route. No UI action or product API creates model intent.

## Grounded design

Confluent's [KRaft quickstart](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/quickstart-deploy/kraft-quickstart) uses one scenario directory, ordered apply steps, and a real producer/consumer check. This example keeps that executable shape. Kamiwaza improves authority boundaries: administrator policy owns namespace, registry, trust, and Gateway choices; tenant YAML owns platform and model intent; the operator continuously reconciles both.

## Prerequisites

- Kubernetes version, operator chart, and compatibility bundle supported by the selected Kamiwaza release.
- Dynamic RWO StorageClass; replace `example-rwo` in `operator-values.yaml`, `platform.yaml`, and `model-deployment.yaml`.
- Administrator-owned Gateway `kamiwaza-gateway`, DNS for `first-chat.example.invalid`, certificate Secret `kamiwaza-gateway-tls` with `tls.crt`, `tls.key`, and `ca.crt`, and required certificate controllers.
- Existing pull Secrets `registry-pull` and `kamiwaza-registry-credentials` in `kw-first-chat`.
- Existing Secret `first-chat-client` in `kw-first-chat` with one short-lived bearer token under key `token`. Never commit it.

Install the operator with the reviewed chart and `operator-values.yaml` before applying tenant resources. Replace every example domain and registry endpoint first.

## Apply

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
```

## Observe

```bash
kubectl -n kw-first-chat wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-first-chat wait --for=condition=Ready modeldeployment/smollm2-cpu --timeout=20m
kubectl -n kw-first-chat get httproute,job,pod
kubectl -n kw-first-chat logs job/first-chat-check
```

Expected check output names model `smollm2-135m-instruct`, a stop reason, and no answer text or credential. If `ModelDeployment` is Ready but the governed route cannot resolve `smollm2-cpu`, inventory projection is incomplete. Do not repair that by calling an imperative model API; record it as an operator/application contract failure.

## Failure and reapply

A missing Secret or unavailable storage class remains visible through conditions. The Job uses bounded backoff. Reapplying the directory is a no-op for converged resources and never creates a second model identity.

## Cleanup

```bash
kubectl -n kw-first-chat delete job/first-chat-check modeldeployment/smollm2-cpu kamiwazaplatform/kamiwaza
kubectl -n kw-first-chat get pvc
```

`RetainData` preserves platform and model claims. Delete retained PVCs only after reviewing their contents. The Gateway, controller installations, and prerequisite Secrets remain administrator-owned.
