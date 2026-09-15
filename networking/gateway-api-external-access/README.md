# Gateway API external access

## Purpose

Publish web, API, model, identity-discovery, and enabled catalog routes through one administrator-owned Gateway. The operator creates only standard `HTTPRoute` children.

## Grounded design

Confluent's [external LoadBalancer example](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/networking/external-access-load-balancer-deploy) separates cluster resources from client checks. Kamiwaza keeps that separation but uses only Kubernetes Gateway API. No `Ingress`, provider CRD, vendor annotation, routing adapter, or controller install appears here.

## Ownership and prerequisites

The cluster administrator owns `gateway.yaml`, `kamiwaza-gateway-tls`, DNS, and the conformant Gateway controller. Replace `replace-with-conformant-class`, `gateway-access.example.invalid`, and `example-rwo`. Install the operator with `operator-values.yaml`; create required image-pull and registry Secrets without committing values. The platform owner applies `platform.yaml` and `access-checks.yaml`.

The Gateway must report `Accepted=True`, `Programmed=True`, and `ResolvedRefs=True` at its current generation. Each generated `HTTPRoute` must report `Accepted=True` and `ResolvedRefs=True`. A stale condition does not prove routing.

## Apply

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-gateway-access wait --for=condition=Programmed gateway/kamiwaza-gateway --timeout=10m
kubectl -n kw-gateway-access wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-gateway-access get httproute -o wide
kubectl -n kw-gateway-access logs job/gateway-access-checks
```

The check requires public frontend and discovery success, protected API/model responses, catalog routing, verified TLS, and denied direct access to `core-api`. A CNI that does not enforce `NetworkPolicy` fails the isolation check and is not equivalent.

## Failure and cleanup

A missing TLS Secret or rejected listener remains `EdgeListenerUnverified`; the operator must not create or take ownership of the Gateway. Repair the Gateway or Secret declaratively, then reapply. No fixed sleep or child-object patch is used.

```bash
kubectl -n kw-gateway-access delete job/gateway-access-checks kamiwazaplatform/kamiwaza
kubectl -n kw-gateway-access get pvc
```

Delete the Gateway or TLS Secret only through the administrator workflow that created them. `RetainData` leaves platform claims for review.
