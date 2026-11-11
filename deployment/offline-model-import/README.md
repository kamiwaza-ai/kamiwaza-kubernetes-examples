# Offline model import (air-gapped)

**Scenario:** an air-gapped install that receives only container images needs
to run a Hugging Face model on the platform's own engines (llama.cpp, vLLM).
Without internet access, a model download fails with HTTP 503 and a message
`Model hub (huggingface.co) unreachable`. Pack the model into an image on a connected
machine, move the image with your other images, and import it with one Helm
value.

**Kamiwaza 1.4.1 and later.** **Tags:** #deployment #offline #models #helm-values

Full procedure, sizing and every error: the Kamiwaza docs page
**Import a Model Without Internet Access** (`models/offline-model-import`).

## Prerequisites

- Kamiwaza 1.4.1 or later, installed with Helm, using the built-in model
  registry (neither `global.modelRegistry` nor `core.scheduler.registryExternalHost` set).
- The 1.4.1 field kit, with `kz-model-pack.sh`, on a machine that reaches
  `huggingface.co`.
- Free space in the platform's model registry: at least 1.1 times the model
  size. The import checks this before it pushes anything.

## Steps

1. **Pack** (connected side). Keep the image reference and the manifest sha256
   it prints:

   ```bash
   bash kz-model-pack.sh pack Qwen/Qwen3-0.6B-GGUF --revision <commit> \
     --image registry.example.com/models/qwen3-0.6b-gguf:1
   ```

2. **Transfer** the image to your site registry, at
   `<global.imageRegistryPrefix>/images/qwen3-0.6b-gguf:<tag>`. A transfer that
   changes the digest is fine.

3. **Verify** (site side):

   ```bash
   bash kz-model-pack.sh verify <prefix>/images/qwen3-0.6b-gguf:<tag> --manifest-sha256 <sha256>
   ```

4. **Configure.** Merge the entry the pack printed into your values file.
   [`values-snippet.yaml`](values-snippet.yaml) shows its shape.

5. **Import.** Run `helm upgrade` with all your values files, in the usual order.

## Verification

```bash
kubectl -n kamiwaza get jobs -l kamiwaza.ai/offline-model-import=qwen3-0-6b
kubectl -n kamiwaza logs job/<job name from the line above> -c import --tail=1
```

The last line is a JSON receipt. `"changed": true` means the model was imported
now; `"changed": false` means it was already there. Then open **Models** in the
UI: the model shows as downloaded. Deploy it.

The Job is `core-model-import-<name>-<hash>`; the hash covers the entry and the
Core image, so an unchanged upgrade does not rerun it. To retry a failed import
without changing values, `kubectl -n kamiwaza delete job <job name>` and rerun
the same `helm upgrade`.

## Alternative

If your site already serves the model from an HTTPS endpoint, register it as an
external model instead (docs: **OpenAI-Compatible Chat**). For a private CA,
see [security/tls-trust](../../security/tls-trust).
