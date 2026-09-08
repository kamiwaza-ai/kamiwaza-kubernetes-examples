# Custom Bedrock region enablement

**Scenario:** drive a **custom / non-default AWS Bedrock endpoint** (a region that is
not in botocore's bundled region list) from Kamiwaza on Kubernetes. botocore ships
endpoint data only for the regions baked into the version installed, so a custom
region is unknown and a Bedrock call against it is rejected **inside the pod** before
any network I/O. This packages a small `sitecustomize.py` botocore patch as a
**declarative, sync-durable** ConfigMap + Helm values overlay.

**Tags:** #security #bedrock #botocore #helm-values

> **This is the companion to the parent [`../`](../README.md) CA-trust recipe.**
>
> - **Region patch (here):** makes boto3 _accept_ the custom region.
> - **CA trust (parent):** makes the TLS handshake to the privately-signed endpoint
>   _succeed with verification ON_.
>
> Apply **both** and you do **not** need `SSL_VERIFY=False` / `AUTH_GATEWAY_TLS_INSECURE`.

---

## Why declarative (not `kubectl patch` / `kubectl edit`)

A common stopgap uses `kubectl set env`, `kubectl patch deployment core-scheduler`,
and `kubectl edit raycluster core-raycluster`. On an **ArgoCD/helm-managed** cluster
those imperative edits are **reverted on the next sync**, silently breaking Bedrock
again. The same volume/env applied through `core.scheduler.*` values is rendered by
the chart on every sync and **flows to the scheduler AND every Ray head/worker** (they
all read `scheduler.extraEnv` / `scheduler.extraVolumes` / `scheduler.extraVolumeMounts`),
so there is no separate `kubectl edit raycluster` step.

| Imperative (gets reverted)                                        | Declarative (here)                                     |
| ----------------------------------------------------------------- | ------------------------------------------------------ |
| `kubectl create configmap botocore-region-hotfix --from-file=...` | `kubectl apply -k .` (kustomize)                       |
| `kubectl set env deployment/core-scheduler PYTHONPATH=...`        | `core.scheduler.extraEnv`                              |
| `kubectl patch deployment core-scheduler` (volume+mount)          | `core.scheduler.extraVolumes` + `extraVolumeMounts`    |
| `kubectl edit raycluster core-raycluster` (head + every worker)   | covered automatically by the same `scheduler.*` values |

---

## Compatibility

| Item                          | Status                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Validated against             | **Kamiwaza 0.13.0** (k8s / Ray path)                                                                                                                       |
| 0.13.0 backend URL validation | Backend accepts custom endpoint URLs; only the **frontend** rejects non-`amazonaws.com` → register via API (see below).                                    |
| 0.10.0 (systemd/Docker)       | Out of scope here — that host-side path also needs an `AWSBedrockEngine._validate_endpoint_url` shim and a `botocore/session.py` edit, not a k8s manifest. |

> The proper code-side fix (per-endpoint region/CA fields, retiring the monkeypatch)
> is tracked as platform follow-up work. This is the configuration-only stopgap.

---

## Files

| File                                                                     | Purpose                                                                                      |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| [`sitecustomize.py`](sitecustomize.py)                                   | Botocore region patch; reads `KAMIWAZA_EXTRA_BEDROCK_REGIONS` (no Python edits needed).      |
| [`kustomization.yaml`](kustomization.yaml)                               | Generates ConfigMap `botocore-region-hotfix` from `sitecustomize.py`.                        |
| [`values-snippet.yaml`](values-snippet.yaml)                             | Mounts it at `/app/hotfix`, prepends to `PYTHONPATH`, sets the region env — scheduler + Ray. |
| [`bedrock-custom-model.example.json`](bedrock-custom-model.example.json) | Reference API payload to register the custom Bedrock endpoint (bypasses the FE URL check).   |

---

## Steps

```bash
# 1. Create the ConfigMap from sitecustomize.py
kubectl apply -k security/tls-trust/bedrock-custom-region

# 2. Merge values-snippet.yaml into cluster/values/overrides.yaml.
#    Set KAMIWAZA_EXTRA_BEDROCK_REGIONS to your EXACT region code(s).
#    If you are also applying the parent CA-trust recipe, merge its
#    AWS_CA_BUNDLE/SSL_CERT_FILE into the SAME core.scheduler.extraEnv list.

# 3. Sync + roll
helmfile -f cluster/helmfile.yaml.gotmpl -e full sync
kubectl -n kamiwaza rollout status deploy/core-scheduler
kubectl -n kamiwaza delete pod -l ray.io/cluster=core-raycluster --wait=false
kubectl -n kamiwaza wait pod -l ray.io/cluster=core-raycluster,ray.io/node-type=head \
  --for=condition=Ready --timeout=300s
```

### Verify the patch is live

```bash
REGION="your-region-1"   # the region code you configured
HEAD=$(kubectl -n kamiwaza get pod -l ray.io/cluster=core-raycluster,ray.io/node-type=head -o name | head -1)
kubectl -n kamiwaza exec "$HEAD" -c ray-head -- \
  python -c "import botocore.session; print('$REGION' in botocore.session.Session().get_available_regions('bedrock'))"
# Expected: True
```

### Register the custom Bedrock endpoint (API path — FE would reject the URL)

```bash
# Edit bedrock-custom-model.example.json (model id, region, endpoint_url, credentials), then:
curl -sk -H 'Content-Type: application/json' -H 'X-User-URN: urn:li:corpuser:admin' \
  -X POST https://<your-domain>/api/models/ \
  -d @security/tls-trust/bedrock-custom-region/bedrock-custom-model.example.json
```

**Pass:** a Bedrock chat completion against the custom endpoint succeeds — region
accepted (this patch) **and** TLS verified (parent CA-trust recipe), no `SSL_VERIFY=False`.

---

## Recovery

```bash
# Remove the hotfix: drop the values block + re-sync, then delete the ConfigMap.
helmfile -f cluster/helmfile.yaml.gotmpl -e full sync
kubectl -n kamiwaza delete configmap botocore-region-hotfix
```

No data loss; pods revert to stock botocore behavior on next roll.

---

## Notes

- Never set `SSL_VERIFY=False` here. The whole point of pairing with the parent recipe
  is to keep TLS verification ON for the privately-signed endpoint.
- `sitecustomize` is auto-imported by CPython when `/app/hotfix` is on `PYTHONPATH`;
  no app code is modified.
- Use **exact** region strings. botocore matches them literally.
