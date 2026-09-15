# Controlled outbound access

## Purpose

Allow one extension to reach one administrator-approved destination class through an external enforcing proxy. Direct, unlisted, IP-literal, and link-local requests remain denied.

## Grounded design

Network infrastructure is an explicit prerequisite. The operator never installs or configures a proxy, mesh, CNI, or DNS policy. Administrator policy owns hosts, ports, trust, proxy authority, and conformance evidence.

## Prerequisites

- Administrator-owned TLS proxy Service `egress-proxy` in `egress-system`, labeled `app.kubernetes.io/name=egress-authority`.
- Existing ConfigMaps `enterprise-trust` and `proxy-conformance` in manager security scope.
- Existing Secret `extension-egress` in `kw-controlled-egress` with `HTTPS_PROXY` and `DESTINATION_URL`. Set the destination to the reviewed HTTPS echo authority. Do not commit values.
- CNI enforcement of Kubernetes NetworkPolicy.

The proxy must verify destination name, port, resolution, redirects, DNS rebinding, and policy revision before loading credentials. The operator only projects references and NetworkPolicy.

## Apply and check

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-controlled-egress wait --for=condition=Ready extension/outbound-client --timeout=10m
kubectl -n kw-controlled-egress logs job/egress-check
```

The check sends only a destination class. The extension obtains proxy and destination endpoints from an existing Secret and logs neither. One proxy request must return the expected marker. Four active probes must fail: unlisted public authority, direct approved-authority bypass, IP literal, and `169.254.169.254`.

## Contract gap exposed

Current clean `Extension` API has no typed destination-class field. `config.destinationClasses` is preserved JSON, so the operator cannot validate the selection or publish egress status from it. This scenario therefore requires both active NetworkPolicy/proxy checks and fails the tenant-policy boundary until a supported class-selection contract exists. Do not move the host or proxy URL into tenant intent.

Stop the external proxy in a disposable cluster. The extension must report an egress dependency wait with bounded retry and stay closed. Restore the same proxy and require recovery. An unknown class is terminal until intent changes; it is not retried as an outage.

## Cleanup

```bash
kubectl delete -k .
```

Do not delete the external proxy, trust source, evidence object, or its credentials. Reapply must be a no-op.
