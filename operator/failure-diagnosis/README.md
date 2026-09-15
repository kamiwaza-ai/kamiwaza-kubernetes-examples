# Condition-driven failure diagnosis

## Purpose

Introduce one declarative fault at a time. Diagnose from API validation, root conditions, capability or model conditions, owned children, then Kubernetes Events and workload logs. Repair desired state through server-side apply.

## Grounded design

Confluent's [CFK troubleshooting guide](https://docs.confluent.io/operator/current/co-troubleshooting.html) starts with custom-resource status, Kubernetes resources, Events, and logs. Kamiwaza keeps that evidence order but uses capability-specific conditions, observed generations, upstream Kubernetes reasons, and explicit terminal or transient classification. Product-specific imperative recovery commands are unnecessary.

## Prerequisites

- Fresh disposable namespace for each case.
- Operator installed from `operator-values.yaml`.
- Existing platform Secrets named by `base/platform.yaml`, `provider-credential`, `enterprise-oidc-client`, `failure-client`, `kamiwaza-gateway-tls`, and `malformed-provider-tls` with the Service DNS SAN.
- StorageClass `example-rwo`, a conformant Gateway API controller, and a real class substituted for `replace-with-conformant-class`.
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

| Case                          | Exact expected evidence                                                                                                                                               | Classification and independent progress                                                                                                                                       |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `admission-rejection`         | API server rejects `spec.profile=Development`; no object, generation, or status exists.                                                                               | Terminal input. `repair.yaml` uses the only current value, `Full`.                                                                                                            |
| `missing-secret`              | Model `phase=Pending`, `Ready=False`, reason `ProviderCredentialPending`; message names `absent-provider-credential`.                                                 | Transient. Creating or selecting an existing Secret wakes reconciliation. Platform remains independent.                                                                       |
| `unavailable-storage`         | Storage policy reports `StorageReady`; durable data remains `Progressing/DataWorkloadsProgressing`; PVCs and Pods show Pending.                                       | Transient infrastructure wait. Other independent roots still reconcile.                                                                                                       |
| `rejected-gateway-route`      | HTTPRoute parent condition reports `Accepted=False/NoMatchingListenerHostname`; affected platform component copies reason `NoMatchingListenerHostname`.               | Terminal desired Gateway mismatch until hostname changes. Internal workloads remain available.                                                                                |
| `image-pull-failure`          | Model remains `phase=Reconciling`, `Ready=False`; reason is the exact current kubelet reason, normally `ErrImagePull` then `ImagePullBackOff`.                        | Transient for a temporarily unavailable registry; terminal for this nonexistent digest. Do not normalize upstream reasons.                                                    |
| `unsatisfied-model-placement` | Model remains `phase=Reconciling`, `Ready=False`, reason `Unschedulable`; PodScheduled carries scheduler details.                                                     | Transient capacity wait. No controller-side Node selection or binding.                                                                                                        |
| `identity-dependency-outage`  | OIDC method capability reports `EgressEnforcementUnavailable` with retry class `Transient`; authentication remains fail-closed.                                       | Built-in data, storage, model, and internal reconciliation continue. Recovery uses same profile when IdP returns; supplied repair switches back to reviewed built-in profile. |
| `malformed-provider-response` | Model currently reports `Ready=True/HostedByProvider` after only Secret presence validation; an authenticated application chat call fails on malformed provider JSON. | Missing public provider-health projection is a scenario failure, not a clean result. Valid provider response repair must make chat succeed.                                   |

General platform status does not serialize a `retryClass` field for every reason. Do not invent one in output. Use published reason semantics and observe bounded retry behavior.

## Repair

```bash
kubectl apply --server-side --field-manager=platform-operator-user -f cases/<case>/repair.yaml
kubectl -n kw-failure-diagnosis get kamiwazaplatform,modeldeployment -w
```

For admission rejection, apply `repair.yaml` after the rejected create. For provider repair, delete and recreate only any completed validation Job you added; do not delete operator-owned Pods. Require `status.observedGeneration == metadata.generation`, then repeat the end-user service probe.

Transient cases must recover when the dependency returns. They keep retained data and avoid unchanged condition writes or synchronized retries. Terminal cases remain stopped until desired input changes.

Never edit status, remove finalizers, delete Pods as a workaround, force ownership, use fixed sleeps, or mutate product APIs. Delete namespace after each case to remove fault fixtures.
