# Cross-Kamiwaza federation

## Purpose

Declare two independent Kamiwaza clusters that trust and reach each other without merging trust domains or transferring resource authority. Each cluster accepts its own one-way `FederationLink`; mutual connectivity requires both links.

## Contract status

`federation.kamiwaza.io/v1alpha1 FederationLink` and `adminPolicy.federation` are proposed operator contracts. The current operator does not install this CRD or reconcile these fields. `kubectl kustomize` can render each cluster now; server-side apply must remain blocked until the API, CEL rules, status contract, and controller described here exist.

No routing implementation appears in public intent or status. A reviewed release still pins its selected protocol-plane image in administrator-owned release data.

## Grounded design

SPIFFE federation relationships are one-way. Each side explicitly configures the foreign trust domain, bundle endpoint, and endpoint profile. Bundles remain distinct. Mutual authentication therefore needs reciprocal acceptance, not a shared root or one cluster controlling the other.

Kubernetes Gateway API supplies provider-neutral attachment and route status. The platform operator owns local trust projection, local route configuration, and observed status. Platform authorization continues to own model, agent, and tool grants.

References:

- <https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Federation.md>
- <https://gateway-api.sigs.k8s.io/>

## Boundaries

- Tenant `FederationLink` contains only desired state and an administrator profile reference.
- Administrator profile binds remote cluster ID, protocol destination class, trust domain, bundle endpoint, bundle destination class, and exact accepted workload identities. Each destination class solely owns its reviewed host and port.
- Remote membership grants no resource access. Configure a narrow resource-owner grant for `federation-contract-model` before running the check.
- Bundle refresh uses the last verified bundle for at most `maximumBundleStaleness`. New remote authentication fails after that bound.
- Decision-service failure denies before remote backend I/O.
- Suspension and deletion remove local acceptance and route state only. They never delete remote objects or the reciprocal link.

## Files and contexts

| Cluster | Administrator policy              | Tenant entry point                |
| ------- | --------------------------------- | --------------------------------- |
| east    | `admin/east-policy-fragment.yaml` | `cluster-east/kustomization.yaml` |
| west    | `admin/west-policy-fragment.yaml` | `cluster-west/kustomization.yaml` |

Use two explicit kubeconfig contexts. Never run both Kustomizations against one cluster.

## Render now

```bash
kubectl kustomize cluster-east
kubectl kustomize cluster-west
```

## Apply after operator support exists

Merge each policy fragment into the corresponding cluster's [shared operator installation](../../operator/quickstart/) and update that release through the chart upgrade workflow. Create the existing `federation-check-token` Secret in each namespace from a short-lived token for a principal with the documented remote grant; do not commit the token.

Each `platform.yaml` carries one intentionally non-pullable, provider-neutral image pin only to satisfy the current CRD shape. Replace `spec.images.pinned` with the complete reviewed release inventory and replace `example-rwo` before apply.

Each check Job mounts the operator-projected `kamiwaza-trust-bundle` ConfigMap and verifies the namespace-local protocol-plane certificate. Cleartext and certificate verification bypasses are outside this contract.

```bash
kubectl --context kamiwaza-east diff --server-side --field-manager=platform-operator-user -k cluster-east
kubectl --context kamiwaza-west diff --server-side --field-manager=platform-operator-user -k cluster-west
kubectl --context kamiwaza-east apply --server-side --field-manager=platform-operator-user -k cluster-east
kubectl --context kamiwaza-west apply --server-side --field-manager=platform-operator-user -k cluster-west
kubectl --context kamiwaza-east -n kw-federation-east wait --for=condition=Ready federationlink/west --timeout=10m
kubectl --context kamiwaza-west -n kw-federation-west wait --for=condition=Ready federationlink/east --timeout=10m
kubectl --context kamiwaza-east -n kw-federation-east logs job/federation-check
kubectl --context kamiwaza-west -n kw-federation-west logs job/federation-check
```

Expected status includes `TrustBundleReady`, `RemoteIdentityVerified`, `TransportReady`, and `Ready`, all for the observed generation. Status exposes remote cluster ID and trust domain, never credentials or implementation identity.

## Failure exercises

1. Block one bundle endpoint. Existing verified connections may finish within their bound. Status becomes degraded. New remote authentication fails after `15m`.
2. Restore the endpoint. Bundle refresh and traffic recover without editing either link.
3. Set east `FederationLink.spec.state` to `Suspended`. East-to-west traffic stops. West-to-east remains governed by west's independent link.
4. Restore `Active`. Reconciliation reuses the same profile and does not recreate remote state.
5. Rotate a foreign bundle with an overlap window. Both accepted generations work during overlap; the retired key fails after overlap.

## Cleanup

Delete each Kustomization from its own context. Confirm remote resources and retained platform data remain.

```bash
kubectl --context kamiwaza-east delete -k cluster-east
kubectl --context kamiwaza-west delete -k cluster-west
```
