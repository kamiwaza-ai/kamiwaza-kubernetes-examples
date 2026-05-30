# Offline embedding model from an internal HuggingFace

**Scenario:** an **air-gapped / offline** Kamiwaza cluster needs an embedding model
for Context Service RAG (document ingest + search) and the knowledge graph
(Graphiti), but the default model download targets `huggingface.co`, which the
cluster cannot reach. The site already runs an **internal HuggingFace** (a hub
mirror that can serve model files). Repoint Kamiwaza's model downloads at that
internal hub via Helm values — no image rebuild, no manual copy into pods.

**Tags:** #deployment #offline #airgap #embedding #huggingface #rag

> **TLS companion.** If your internal hub is HTTPS with a private/enterprise CA,
> pair this with [`../../security/tls-trust`](../../security/tls-trust) so downloads
> trust it with verification **on**. The embedding chart's download init container
> has no insecure (`-k`) path — serve over HTTP internally (integrity is still
> enforced by the SHA-256 check) or make the CA trusted.

---

## Two embedding consumers, two knobs

A release/offline install feeds embeddings to two independent consumers. Point
**both** at your internal hub:

| Consumer | What it uses | Download mechanism | Knob |
| --- | --- | --- | --- |
| **Context RAG** (file ingest + search) | A **deployed embedding model** (discovered from the Models registry) | Models service → `huggingface_hub` | `HF_ENDPOINT` env |
| **Graphiti** (knowledge graph) | The bundled `core-embedding` service | Embedding chart → `curl` init container | `embedding.model.downloadUrl` (+ `sha256`) |

> **Release pins `autoProvision: false`** (`core.context.embedding`). That means
> Context RAG will **not** auto-create an embedding deployment — the operator must
> **deploy one** (Models UI / API). With no embedding model deployed, ingest fails
> with `NoEmbeddingDeployedError: Auto-provisioning is disabled and no embedding
> model is deployed. Deploy one in the Models UI.`

---

## Files

| File | Purpose |
| --- | --- |
| [`values-snippet.yaml`](values-snippet.yaml) | Merge into Deploy `cluster/values/overrides.yaml`: route both download paths at the internal hub. |

---

## Steps

### 1. Confirm model storage is configured and writable

```bash
# The scheduler must be able to write the models path.
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- \
  sh -c 'touch /app/models/.w && rm -f /app/models/.w && echo WRITABLE || echo NOT-WRITABLE'
```

### 2. Confirm the internal hub serves the GGUF

llama-server loads **GGUF** (not safetensors). The platform default is
`all-MiniLM-L6-v2` Q8_0. Confirm your hub serves it (or an equivalent embedding
GGUF) at a `/resolve/` URL, **and** that the `/resolve/` redirect target
(LFS/CDN backend) is reachable in-cluster — the download follows that redirect.
Get the SHA-256 from the LFS pointer without downloading the whole file:

```bash
curl -sL "https://<internal-hf>/<repo>/raw/<branch>/<file>.gguf"
# version https://git-lfs.github.com/spec/v1
# oid sha256:<HASH>      <- use this for embedding.model.sha256
# size <bytes>
```

### 3. Point both download paths at the hub (values)

Merge [`values-snippet.yaml`](values-snippet.yaml) into `cluster/values/overrides.yaml`
(`HF_ENDPOINT` for the models service, `embedding.model.*` for `core-embedding`),
then sync:

```bash
helmfile -f cluster/helmfile.yaml.gotmpl -e <env> sync
kubectl -n kamiwaza rollout restart deploy/core-embedding
```

### 4. Download + deploy the embedding model for RAG

In the **Models UI**: search for the embedding model, **Download** it (the pull
goes through `huggingface_hub`, which honors `HF_ENDPOINT` → your hub), then
**Deploy** it. (Release does not auto-provision, so this deploy step is required.)

API equivalent:

```bash
TOKEN=$(curl -sk https://<domain>/api/auth/token \
  -d "username=admin&password=<pw>&grant_type=password&scope=openid email profile roles offline_access" \
  -H 'Content-Type: application/x-www-form-urlencoded' | jq -r .access_token)

# Download (note trailing slash; hub=HubsHf):
curl -sk -X POST https://<domain>/api/models/download/ -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"<repo>","hub":"HubsHf","files_to_download":["<file>.gguf"],"deploy_after_download":false}'

# After the file lands, deploy it (model + embedding config ids from /api/models/):
curl -sk -X POST https://<domain>/api/serving/deploy_model -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"m_id":"<model-id>","m_config_id":"<embedding-config-id>","engine_name":"llamacpp","engine":"llamacpp","min_copies":1,"starting_copies":1}'
```

### Verify

```bash
# Embedding model deployment is DEPLOYED
curl -sk https://<domain>/api/serving/deployments -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.status=="DEPLOYED") | "\(.m_name)\t\(.status)"'

# Graphiti's core-embedding serves a vector
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- /app/.venv/bin/python - <<'PY'
import httpx
r = httpx.post("http://core-embedding.kamiwaza.svc:8080/v1/embeddings",
               json={"input": ["hello"], "model": "all-MiniLM-L6-v2"}, timeout=30)
print("core-embedding HTTP", r.status_code, "dim", len(r.json()["data"][0]["embedding"]))
PY
```

Then upload a small document to a workroom (Context → Imports → **Stage from
sources**) and confirm the import completes (no `NoEmbeddingDeployedError`).

**Pass:** an embedding model shows `DEPLOYED`, `core-embedding` returns a vector
(`dim 384` for all-MiniLM-L6-v2), and a document import completes with chunks
generated.

---

## Known 0.13.0 import issues (fixed in 0.13.1)

Three context-import issues ship in 0.13.0 and are fixed in **0.13.1**. If you are
pinned to 0.13.0 (e.g. an offline/air-gapped install that cannot take new bits),
the first is a **correctness** problem and is worth working around with config; the
other two are latency only.

| Issue | Impact on 0.13.0 | Workaround on 0.13.0 (no new bits) |
| --- | --- | --- |
| **Chunk size exceeds embedding context** (ENG-6111) | The chunker default (800 tokens) is larger than `all-MiniLM-L6-v2`'s 512-token ceiling. A single oversize chunk makes llama-server return **HTTP 500 (empty body)**, which **fails the entire file** — not slow, *broken*. Content-dependent, so it hits any sufficiently long/dense document regardless of hardware. | **Config override** — set `CONTEXT_SERVICE_OMNIPARSE_DEFAULT_MAX_TOKENS=500` (in the values snippet). Keeps every chunk inside the model context. This is the 0.13.1 default applied early. |
| **Single-slot embedder** (ENG-6075) | The embedding deployment runs `--parallel 1` on CPU (~3s/vector). Large imports are slow, and a 32-chunk batch (~85–110s) blows the default 30s call timeout → `Failed to reach embedding service` (ReadTimeout). | **Raise the timeout** — `CONTEXT_SERVICE_EMBEDDING_TIMEOUT=600` (in the values snippet). Does **not** speed up embedding, just stops the premature timeout. |
| **Per-file readiness wait** (ENG-6094) | The pipeline waits up to 120s **per file** for a VectorDB readiness probe that has already passed — pure wasted latency, no functional impact. | **None via config** (it's a logic bug, not a tunable). Eat the latency on 0.13.0; it's gone in 0.13.1. |

> **The chunk-size override and the timeout bump are independent.** Raising the
> timeout does nothing for the oversize-chunk failure — that's a content-size 500,
> not a slow call. On 0.13.0 you want **both** env vars set.

**Trade-off of the 500-token chunk size:** smaller chunks mean more chunks per
document (slightly more vectors stored and more embedding round-trips), often with
*better* RAG retrieval precision. Safe regardless of which embedding model you
deploy — if you later bind a larger-context model, 500-token chunks still work.

---

## Recovery

```bash
# Remove the HF_ENDPOINT + embedding.model.* overrides from overrides.yaml, re-sync,
# and roll core-embedding back to the chart default.
helmfile -f cluster/helmfile.yaml.gotmpl -e <env> sync
kubectl -n kamiwaza rollout restart deploy/core-embedding
```

---

## Notes

- **Raise the embedding timeout (strongly recommended).** `CONTEXT_SERVICE_EMBEDDING_TIMEOUT`
  defaults to **30 seconds and is *not* overridden by the charts**, and it applies **per batch**
  of `CONTEXT_SERVICE_EMBEDDING_BATCH_SIZE` chunks (default 32), not per file. On real workloads —
  large documents, slow or loaded embedders, CPU-only nodes — a single batch routinely exceeds 30s
  and the import fails with `Failed to reach embedding service` (ReadTimeout). The values snippet
  sets it to **600s**; raise further if one batch on your hardware can take longer, and/or lower
  the batch size. (The overall per-job ceiling is separate: context-service `job_timeout_seconds`,
  default 3600 / 1h.)
- **Format:** the embedder needs a **GGUF**; a safetensors-only repo won't load.
  Convert offline if your hub only has the original sentence-transformers repo.
- **Redirect reachability:** HuggingFace `/resolve/` URLs 302 to a separate
  LFS/CDN host. The download follows it, so that backend must be reachable
  in-cluster too — test the *file* fetch, not just the index.
- **Checksum:** `embedding.model.sha256` must match the bytes your hub serves, or
  `core-embedding`'s `verify-model` init container fails and the pod never starts.
- **Auth:** for a token-gated hub, supply `embedding.huggingface.existingSecret`
  (the chart injects `Authorization: Bearer <token>` for the `core-embedding`
  download) and a HuggingFace token for the models service (`HF_TOKEN`) so
  `huggingface_hub` authenticates against `HF_ENDPOINT`.
- **RAG needs a *deployed* model:** the `core.context.embedding.serviceUrl` pin
  feeds Graphiti, not RAG. RAG resolves a model from the Models registry — deploy
  one (step 4). This is why `autoProvision: false` requires the explicit deploy.
- **Dimension:** all-MiniLM-L6-v2 is 384. If you substitute a different embedder,
  keep its dimension consistent and re-create collections built at the old size.
