# Certificate ownership and rotation

## Purpose

Validate three certificate authorities without moving ownership between them: platform-issued, external-controller-issued, and administrator-supplied. Exercise renewal and key replacement through durable annotation requests.

## Grounded design

External certificate controllers remain optional. One administrator policy selects one authority; tenant intent cannot choose an issuer, subject, SAN, key algorithm, or Secret name.

## Ownership matrix

| Mode                    | Request                            | Issue and renew              | Key storage                 | Trust publication                | Delete                            |
| ----------------------- | ---------------------------------- | ---------------------------- | --------------------------- | -------------------------------- | --------------------------------- |
| `PlatformIssued`        | operator                           | operator                     | manager security namespace  | operator                         | explicit operator security policy |
| `ControllerIssued`      | operator creates namespaced intent | approved external controller | controller-owned Secret     | operator observes and publishes  | controller/issuer policy          |
| `AdministratorSupplied` | administrator                      | administrator PKI            | exact administrator Secrets | operator validates and publishes | administrator only                |

Each `variants/*` directory is independent. Use one values file with the [shared operator installation](../../operator/quickstart/#4-install-the-shared-manager), or update that release through the chart upgrade workflow. Never combine modes or install another manager. Replace `example-rwo` and `example.invalid`. Never commit private keys, certificate payloads, passwords, private endpoints, generated Secrets, or exported Kubernetes objects containing `data`.

## Apply and verify

```bash
MODE=platform-issued
kubectl apply --server-side --field-manager=platform-operator-user -k variants/${MODE}
kubectl -n kw-cert-platform wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-cert-platform logs job/certificate-check
```

The check verifies a real TLS handshake with the published `kamiwaza-trust-bundle` and prints only its SHA-256 digest. Status must publish ownership, authority generations, trust digest, current-generation consumers, and expiry state. Status, Events, logs, and metrics must never expose certificate or key bodies.

`PlatformIssued` must work with no certificate-controller CRD. `ControllerIssued` must create only namespaced certificate intent and report `IssuerIntentUnfulfilled` during issuer outage. `AdministratorSupplied` must create no certificate intent, never mutate the source Secrets, retain the last valid identity on malformed replacement, and report `SuppliedMaterialInvalid` or `SuppliedMaterialExpiring`.

## Manual rotation

Apply one request through the same desired-state field manager:

```bash
kubectl apply --server-side --field-manager=platform-operator-user -f rotation/renew-certificate.yaml
kubectl -n kw-cert-platform get kamiwazaplatform/kamiwaza -o jsonpath='{.status.transport.rotation}'
```

Reapplying the unchanged request must not start another operation. To repeat a completed request, commit and apply `rotation/clear-request.yaml`, wait until the request ledger clears, then commit and apply the chosen request again.

For key replacement:

```bash
kubectl apply --server-side --field-manager=platform-operator-user -f rotation/replace-key.yaml
kubectl -n kw-cert-platform get configmap/kamiwaza-trust-bundle -o jsonpath='{.metadata.labels.transport\.kamiwaza\.io/bundle-digest}{"\n"}'
kubectl -n kw-cert-platform wait --for=condition=complete job/certificate-check --timeout=5m
```

Require ordered phases: publish replacement and retiring anchors, issue leaves under replacement, prove every consumer generation, then retire old anchor. Keep the handshake green throughout. Rotation does not revoke already issued credentials. Revoke through the issuing authority's separate incident procedure.

When another party holds the key, the same request reports that party's action. Replace its declared material or fulfill its certificate intent. The operator must not seize or synthesize the key.

## Restart, failure, and cleanup

Restart the manager once during replacement. Reconciliation must resume the observed phase without duplicate key generation or early anchor retirement. Malformed input, trust mismatch, and issuer timeout retain the last valid identity and produce cause-specific conditions.

```bash
kubectl delete -k variants/platform-issued
kubectl -n kw-cert-platform get pvc
```

`RetainData` preserves platform PVCs. Administrator-supplied and external-controller-owned Secrets remain untouched.
