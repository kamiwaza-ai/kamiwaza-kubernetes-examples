# Consent banner and pre-login consent gate

**Scenario:** ship consent modal HTML as a Kubernetes `ConfigMap`, mount it on **core-scheduler**, and enable `security.consent` / optional classification banners via Helm values (self-contained manifests, explicit order, verification).

**Tags:** #security #compliance #kustomize #helm-values

## What you get

- **`consent-configmap`** in namespace **`kamiwaza`** (key **`consent.html`**).
- Values fragment **`core-values-snippet.yaml`** to merge into the **Kamiwaza Deploy** repo’s **`cluster/values/overrides.yaml`** (`core.scheduler.extraVolumes` / `extraVolumeMounts`).

## Prerequisites

- A Kamiwaza install (Helmfile from [Kamiwaza Deploy](https://github.com/kamiwaza/deploy)) with namespace **`kamiwaza`**.
- `kubectl` + `kubectl apply -k`.

## Steps

### 1. Edit consent copy (optional)

Edit **`consent.html`** in this directory.

### 2. Apply the ConfigMap

From a clone of **this** repo (`kamiwaza-kubernetes-examples` root):

```bash
kubectl apply -k security/consent-banner/
```

Or from this directory:

```bash
kubectl apply -k .
```

### 3. Merge Helm values

Copy the **`core:`** block from **`core-values-snippet.yaml`** into **`cluster/values/overrides.yaml`** in your Deploy checkout (or merge manually). Adjust banner text/colors.

### 4. Roll out

**New install:** from Deploy repo, `make install` / `helmfile sync` for your environment (with auth enabled if you use the full UI).

**Already running:** after ConfigMap-only changes:

```bash
kubectl rollout restart deployment/core-scheduler -n kamiwaza
```

Mounts using **`subPath`** usually require a pod restart to pick up updated file content.

## Verification

```bash
kubectl -n kamiwaza get configmap consent-configmap -o yaml
kubectl -n kamiwaza get deployment core-scheduler -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}{"\n"}'
```

With consent enabled in values, open the UI and confirm the modal appears before login.

## Ordering (first install)

If the Deployment references **`consent-configmap`** before the object exists, scheduler pods may not start until you **`kubectl apply -k`** this folder, then restart or re-sync. Prefer: **ConfigMap first**, then Helm apply with overrides.

## Files

| File                       | Purpose                                    |
| -------------------------- | ------------------------------------------ |
| `kustomization.yaml`       | `configMapGenerator` from `consent.html`.  |
| `consent.html`             | Modal body (HTML).                         |
| `core-values-snippet.yaml` | Umbrella **`core:`** overrides for Deploy. |
