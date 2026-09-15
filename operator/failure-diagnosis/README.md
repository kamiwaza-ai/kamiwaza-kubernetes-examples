# Condition-driven failure diagnosis

## Purpose

Introduce one declarative fault at a time. Diagnose from API validation, root conditions, capability or model conditions, owned children, then Kubernetes Events and workload logs. Repair desired state through server-side apply.

## Grounded design

Confluent's [CFK troubleshooting guide](https://docs.confluent.io/operator/current/co-troubleshooting.html) starts with custom-resource status, Kubernetes resources, Events, and logs. Kamiwaza keeps that evidence order but uses capability-specific conditions, observed generations, upstream Kubernetes reasons, and explicit terminal or transient classification. Product-specific imperative recovery commands are unnecessary.

## Prerequisites

- Fresh disposable namespace for each case.
- Operator installed from `operator-values.yaml`.
- Existing platform Secrets named by `base/platform.yaml`, `provider-credential`, `enterprise-oidc-client`, `failure-client`, `kamiwaza-gateway-tls`, `malformed-provider-gateway-tls`, and `malformed-provider-tls`. The gateway certificate covers `malformed-provider.failure.example.invalid`; the backend certificate covers the Service DNS SAN. Create administrator trust ConfigMap `malformed-provider-trust` with the matching CA certificate under `ca.crt`.
- StorageClass `example-rwo`, public DNS for both failure hostnames, a conformant Gateway API controller with `BackendTLSPolicy` support, and a real class substituted for `replace-with-conformant-class`.
- OIDC failure case requires `idp-failure.example.invalid` to be deliberately unavailable through the approved destination class.

Never run two cases in one namespace. Each Kustomization imports only this scenario's known-good base.

## Observation order

For case `<case>`:

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k cases/<case>
kubectl -n kw-failure-diagnosis get kamiwazaplatform,modeldeployment -o yaml
kubectl -n kw-failure-diagnosis get kamiwazaplatform kamiwaza -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.observedGeneration}{"\n"}{end}'
kubectl -n kw-failure-diagnosis get kamiwazaplatform kamiwaza -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.state}{"\t"}{.reason}{"\t"}{.observedGeneration}{"\n"}{end}'
kubectl -n kw-failure-diagnosis get deployment,statefulset,job,pod,httproute
kubectl -n kw-failure-diagnosis events --types=Warning
```

Read logs only from child named by status or Event. Never begin with logs.

## Cases

| Case                          | Exact expected evidence                                                                                                                                 | Classification and independent progress                                                                                                                                             |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `admission-rejection`         | API server rejects `spec.profile=Development`; no object, generation, or status exists.                                                                 | Terminal input. `repair.yaml` uses the only current value, `Full`.                                                                                                                  |
| `missing-secret`              | Model has `Ready=False`, reason `ProviderCredentialPending`; message names `absent-provider-credential`.                                                | Transient. Creating or selecting an existing Secret wakes reconciliation. Platform remains independent.                                                                             |
| `unavailable-storage`         | Storage policy reports `StorageReady`; durable data remains `Progressing/DataWorkloadsProgressing`; PVCs and Pods show Pending.                         | Transient infrastructure wait. Other independent roots still reconcile.                                                                                                             |
| `rejected-gateway-route`      | HTTPRoute parent condition reports `Accepted=False/NoMatchingListenerHostname`; affected platform condition copies reason `NoMatchingListenerHostname`. | Terminal desired Gateway mismatch until hostname changes. Internal workloads remain available.                                                                                      |
| `image-pull-failure`          | Model has `Ready=False`; reason preserves the observed kubelet cause, normally `ErrImagePull` then `ImagePullBackOff`.                                  | Transient for a temporarily unavailable registry; terminal for the administrator profile's nonexistent digest. Repair selects the reviewed profile without exposing a Pod template. |
| `unsatisfied-model-placement` | Model has `Ready=False`, reason `Unschedulable`; PodScheduled carries scheduler details.                                                                | Transient capacity wait for the declared accelerator resource. No controller-side Node selection, binding, or CPU fallback.                                                         |
| `identity-dependency-outage`  | OIDC method capability reports `EgressEnforcementUnavailable` with retry class `Transient`; authentication remains fail-closed.                         | Built-in data, storage, model, and internal reconciliation continue. Recovery uses same profile when IdP returns; supplied repair switches back to reviewed built-in profile.       |
| `malformed-provider-response` | Model has `Ready=False`, reason `ProviderResponseInvalid`; message names the selected profile but contains no response body or credential.              | Transient malformed dependency response with bounded retry. Applying the valid response repair makes the same model recover.                                                        |

General platform status does not serialize a `retryClass` field for every reason. Do not invent one in output. Use published reason semantics and observe bounded retry behavior.

## Repair

```bash
kubectl apply --server-side --field-manager=platform-operator-user -f cases/<case>/repair.yaml
kubectl -n kw-failure-diagnosis get kamiwazaplatform,modeldeployment -w
```

For admission rejection, apply `repair.yaml` after the rejected create. For provider repair, delete and recreate only any completed validation Job you added; do not delete operator-owned Pods. Require `status.observedGeneration == metadata.generation`, then repeat the end-user service probe.

Transient cases must recover when the dependency returns. They keep retained data and avoid unchanged condition writes or synchronized retries. Terminal cases remain stopped until desired input changes.

Never edit status, remove finalizers, delete Pods as a workaround, force ownership, use fixed sleeps, or mutate product APIs. Delete namespace after each case to remove fault fixtures.
