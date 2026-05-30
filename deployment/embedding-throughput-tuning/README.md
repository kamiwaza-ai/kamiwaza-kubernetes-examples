# Speed up embedding-heavy imports (CPU + parallel slots)

**Scenario:** embeddings already work (see the **offline embedding model** runbook),
but importing large documents into Context is slow — the built-in `core-embedding`
service runs on CPU with a tight pod CPU limit, so it is the bottleneck for
file ingest. This runbook raises the embedder's CPU ceiling and parallel slots
via Helm values, no image rebuild and no new bits.

**Tags:** #deployment #embedding #performance #tuning #cpu

> **Read this before you apply it.** This is a **tuning** change, not a fix, and it
> is **untested on your hardware**. It does **not** make large-file import *fast* —
> at best ~2–3× (the encoder is still CPU inference). A **3 MB** text file took
> **~47 minutes** on a well-resourced reference box; expect *longer* on a smaller or
> CPU-constrained cluster. It also does **not** fix the oversize-chunk failure
> (see "Prerequisite" below). For a demo/exercise, the cheapest win is still to use
> **small/medium files**. Treat the values here as a starting point you size to your
> own node — see the **Risk** section first.

---

## Prerequisite — large files need the chunk-size cap too

This runbook only changes *throughput*. On its own it will **not** let a large file
finish if the chunker emits a chunk larger than the embedding model's context
(512 tokens for `all-MiniLM-L6-v2`): that chunk returns an empty HTTP 500 and
**fails the whole file**. Set the chunk cap first (from the offline-embedding
runbook):

```yaml
core:
  scheduler:
    extraEnv:
      - name: CONTEXT_SERVICE_OMNIPARSE_DEFAULT_MAX_TOKENS   # keep chunks ≤ model context
        value: "500"
```

Throughput tuning + the chunk cap are **independent and complementary** — large
files need both to complete *and* to complete in tolerable time.

---

## What actually limits import speed

The embedder (`core-embedding`, llama-server on CPU) is the floor for file ingest.
On a default install it runs with a **2-core pod CPU limit** and a small context
window. Even when the node has spare cores, the *pod limit* caps it — so embedding
batches process strictly slowly and serially-ish, and a big document is many
batches back to back.

Raising the limit lets the embedder use more of the cores the node already has;
adding `--parallel N` gives it N inference slots to spread across them; a larger
`--ctx-size` is throughput headroom for the server (it does **not** change the
512-token per-input ceiling — that stays governed by the chunk cap above).

---

## Risk — read before raising the CPU limit

The CPU `limit` is a **ceiling** (CFS-throttled — the embedder physically cannot
exceed it), so the embedder won't "run away." The real hazard is **CPU starvation
of co-located core pods** (scheduler, Ray head, frontend) on a node without spare
cores: under a heavy import the embedder bursts to its new ceiling, other pods miss
their liveness/readiness probes, and they **restart** — a sluggish, flapping cluster
(recoverable by reverting, *not* destroyed).

This matters **especially if you had to reduce resource reservations to fit the
platform on this box** — that usually means little spare CPU. So:

- **Check headroom first:** `kubectl top nodes`. Only raise the limit by roughly the
  number of cores the node is *not* already using. If the node is small (≤4 cores
  total) or already busy, **do not** apply this — accept the slow import instead.
- **Size `--parallel` to the cores you grant** (e.g. `--parallel 4` with `limit: "4"`).
  More slots than cores just adds contention.
- **Keep `requests` low** (≈1 core) so normal scheduling isn't starved; the pod only
  bursts under import load.
- **Bump the memory limit** alongside (4 slots × a 2048 context needs more than the
  default 2Gi).
- **It's fully reversible** — see Recovery.

---

## Files

| File | Purpose |
| --- | --- |
| [`values-snippet.yaml`](values-snippet.yaml) | Merge into Deploy `cluster/values/overrides.yaml`: raise `core-embedding` CPU, slots, context, memory. **Tune the numbers to your node.** |

---

## Steps

### 1. Confirm you have spare CPU

```bash
kubectl top nodes
# Subtract current usage from capacity. The headroom is what you can give the
# embedder. No headroom → stop here; this tuning isn't safe on this box.
```

### 2. Apply the values (sized to your node)

Merge [`values-snippet.yaml`](values-snippet.yaml) into `cluster/values/overrides.yaml`,
adjusting `limits.cpu` / `--parallel` to your headroom, then sync and restart:

```bash
helmfile -f cluster/helmfile.yaml.gotmpl -e <env> sync
kubectl -n kamiwaza rollout restart deploy/core-embedding
kubectl -n kamiwaza rollout status  deploy/core-embedding
```

### 3. (Optional) The RAG model deployed via the Models UI

`core-embedding` is what the knowledge graph (Graphiti) uses. On a release install
where Context RAG resolves a **separately deployed** embedding model, that model's
parallelism/CPU come from its **deploy-time config**, not these chart values —
`--parallel` defaults to **1**. When deploying via the API you can raise it:

```bash
# in the /api/serving/deploy_model body
"engine_args": {"parallel": 4},
"resources":   {"limits": {"cpu": "4", "memory": "4Gi"}}
```

(The Models UI may not surface these; the API does. Same node-headroom rules apply.)

### Verify

```bash
# New CPU limit is in effect
kubectl -n kamiwaza get deploy core-embedding \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="embedding")].resources.limits}{"\n"}'

# Under an active import, the embedder should now burst above 2 cores
kubectl -n kamiwaza top pod -l app=core-embedding

# And no other core pod should be restarting
kubectl -n kamiwaza get pods | grep -vE '([0-9]+)/\1.*Running'
```

**Pass:** during an import `core-embedding` uses more than the old 2 cores, import
wall-clock drops, and no co-located pod restarts under the load.

---

## Recovery

```bash
# Remove the embedding.resources / runtime overrides from overrides.yaml, re-sync,
# and roll core-embedding back to the chart defaults (2-core limit, no --parallel).
helmfile -f cluster/helmfile.yaml.gotmpl -e <env> sync
kubectl -n kamiwaza rollout restart deploy/core-embedding
```

If the cluster started flapping after applying this, reverting + the restart above
returns it to the prior (slow but stable) state.

---

## Notes

- **Expectation setting:** ~2–3× at best. A 3 MB file was ~47 min on a strong box;
  this makes large-file import *tolerable*, not *fast*. Small/medium files remain the
  cheap path for a demo.
- **Two embedders, two knobs:** Graphiti → `core-embedding` (these Helm values);
  Context RAG (release) → a deployed model (its deploy-time `engine_args`/`resources`).
- **`ctx-size` ≠ chunk size:** a larger server context is throughput headroom; per-input
  size is still capped at the model's 512-token ceiling via the chunk cap prerequisite.
- **GPU is the real fix:** if a GPU is available, deploying the embedding model with
  `--n-gpu-layers` dwarfs any CPU tuning. This runbook is the CPU-only stopgap.
