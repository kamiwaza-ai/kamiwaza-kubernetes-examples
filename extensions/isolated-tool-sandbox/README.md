# Isolated tool sandbox

## Purpose

Send one real tool request through an `Extension`. Its component creates an upstream `SandboxClaim`, calls a distinct echo worker, returns the observed result, and requests teardown. The platform declares sandbox capacity but never owns an individual sandbox.

## Grounded design

Tool logic lives in reviewed images while the operator manages workload lifecycle. The artifact owns request behavior; `SandboxPool` only projects capacity into the upstream sandbox API.

## Prerequisites

- Administrator-installed upstream agent-sandbox CRDs and controller.
- Existing `RuntimeClass/gvisor` plus nodes that support it.
- Shared manager installed through the [operator quickstart](../../operator/quickstart/) with this scenario's `operator-values.yaml` and sandbox RBAC enabled only for `kw-tool-sandbox`.
- Reviewed image mirrors for the two pinned images.

The operator must not install or configure the upstream controller, RuntimeClass, node runtime, image mirror, or network implementation.

## Current contract gaps exposed

Current `SandboxPool` does not carry or render `runtimeClassName`. Its renderer also does not project `maxLifetimeSeconds` into upstream claim lifecycle. `Extension` has no typed destination-class selection or typed `Tool` kind; those values can only sit in pass-through config. Therefore `tool-check.yaml` intentionally requires the desired RuntimeClass and the 120-second absolute lifetime. It fails until the operator contract implements those guarantees. Do not remove these assertions, emulate isolation in the ordinary extension Pod, or weaken the check.

## Apply and verify

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-tool-sandbox wait --for=condition=Available sandboxpool/tool-sandboxes --timeout=10m
kubectl -n kw-tool-sandbox wait --for=condition=Ready extension/isolated-tool --timeout=10m
kubectl -n kw-tool-sandbox logs job/tool-check
```

The response must carry a distinct sandbox name and echo the request marker. The check observes Pod isolation metadata and waits for claim removal. Output contains no token, Secret, certificate, request credential, or sandbox response body.

## Negative checks

Use a disposable cluster and the extension's ServiceAccount. Kubernetes must deny cross-namespace Secret reads. Upstream template policy must reject environment and volume injection. Network enforcement must deny host access, an unapproved public authority, IP literals, and `169.254.169.254`. An active probe must run inside the sandbox worker before this requirement passes; inspecting NetworkPolicy alone is not proof.

If the upstream controller, RuntimeClass, or eligible node is absent, capacity and extension conditions must stay waiting. No in-process or ordinary-Pod fallback is acceptable. Restore the prerequisite and require convergence without recreating the Extension.

## Cleanup

```bash
kubectl delete -k .
kubectl -n kw-tool-sandbox get sandboxclaims,sandboxes,pvc
```

External sandbox infrastructure remains. No credential or retained extension state is deleted implicitly.
