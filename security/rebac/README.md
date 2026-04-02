# ReBAC (relationship-based access control)

**Scenario:** turn on **ReBAC** for an **auth-enabled** Kamiwaza install (Keycloak + PostgreSQL), then (optionally) **add custom tenants** with bootstrap manifests, registry entries, and Keycloak JWT claims. Same style as other examples here: **values snippets** for **Deploy**, reference manifests for the **Kamiwaza** app repo.

**Tags:** #security #rebac #auth #helm-values #multi-tenant

## What you get

- **`core.rebac`**: `AUTH_REBAC_ENABLED`, backend, and community fallback in **`core-config`** (via `charts/core/templates/scheduler/configmap.yaml`).
- **`core.scheduler.rebac`**: matching **`AUTH_REBAC_*`** env vars on **core-scheduler** and **Ray** templates (overrides ConfigMap for those keys).
- **Custom tenants (below):** tuple bootstrap manifests, tenant registry, optional registry **enforcement**, Keycloak **`tenant_id` / `tenant`** claims, CLI and HTTP APIs.

## Constraints (read before enabling)

| Requirement                      | Why                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **`auth.enabled: true`**         | ReBAC is not supported in **lite** mode (no Keycloak). The core chart fails template if `rebac.enabled` is true while auth is off.    |
| **Not compatible with `--lite`** | `./scripts/install-dev.sh --lite` and ReBAC cannot be combined.                                                                       |
| **Backend**                      | Today **`postgres`** (default) or **`spicedb`** — see `charts/core/values.yaml` and `charts/core/templates/scheduler/configmap.yaml`. |

## Prerequisites

- Kamiwaza deployed from **Kamiwaza Deploy** with **full auth** (e.g. `make install`, `make dev-full`, or `helmfile -e full sync` — not `install-lite` / `dev` lite path unless you know auth is on).
- Permission to edit **`cluster/values/overrides.yaml`** (or your env’s values chain) and re-sync Helm.
- For **custom tenants**, a checkout of the **Kamiwaza** application repo (for `configs/rebac/*`, `scripts/rebac_tenant.py`, `scripts/rebac_policy.py`).

## Steps — enable ReBAC

### Option A — Fresh install with ReBAC (recommended for labs)

From the **Deploy** repo, enable the same overlay Helmfile uses:

```bash
export KAMIWAZA_REBAC_ENABLED=true
# then your usual install, e.g.:
./scripts/install-dev.sh --rebac
# or: make install   (with KAMIWAZA_REBAC_ENABLED=true in the environment)
```

That pulls **`cluster/values/kamiwaza-rebac.yaml`**, which sets **`core.scheduler.rebac`**. For **ConfigMap alignment**, prefer **Option B** or extend Deploy’s overlay to include **`core.rebac`** as in **`core-values-snippet.yaml`** here.

### Option B — Merge this snippet (existing cluster)

1. Copy the **`core:`** block from **`core-values-snippet.yaml`** into **`cluster/values/overrides.yaml`**.
2. Adjust **`allowCommunityFallback`** for your environment (`false` for stricter production-like behavior).
3. Re-sync the umbrella release, e.g. `helmfile -f cluster/helmfile.yaml.gotmpl -e full sync` (or your usual Make target).
4. Rollout if needed: `kubectl rollout restart deployment/core-scheduler -n kamiwaza`.

## Verification — ReBAC enabled

```bash
# Runtime env on the scheduler (after rollout; pod must be Running)
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- env | grep '^AUTH_REBAC' | sort

# ConfigMap keys when core.rebac is enabled in Helm values
kubectl -n kamiwaza get configmap core-config -o yaml | grep AUTH_REBAC
```

Expect **`AUTH_REBAC_ENABLED=true`** in the container environment when **`core.scheduler.rebac.enabled`** is true. If you only applied Deploy’s minimal **`kamiwaza-rebac.yaml`** (scheduler-only), the ConfigMap may still show `AUTH_REBAC_ENABLED` from chart defaults until you merge **`core.rebac`** from **`core-values-snippet.yaml`**.

---

## Custom ReBAC tenants

ReBAC tuples are scoped by **tenant id**. The platform reads the active tenant from the user’s JWT (**`tenant_id`** and **`tenant`** claims should agree with what your policies expect). Helm’s **`core.scheduler.rebac.defaultTenantId`** (and env **`AUTH_REBAC_DEFAULT_TENANT_ID`**) set the **default** tenant used by bootstrap jobs (e.g. Keycloak seed) and as a reference id — **per-user tenants** require **per-user (or per-group) claims in Keycloak**, not only this default.

### 1. Understand the moving parts

| Piece                         | Role                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Bootstrap manifest**        | YAML under `configs/rebac/tenants/<tenant>.yaml` in the **Kamiwaza** repo: declares initial **tuples** (who owns which logical resources). Parsed by `kamiwaza.services.auth.bootstrap`.                                                                                                                                                                      |
| **`scripts/rebac_tenant.py`** | Operator CLI: **`plan`**, **`bootstrap`**, **`diff`**, **`revoke`**, **`export`** against the live relationship store (PostgreSQL when `AUTH_REBAC_BACKEND=postgres`).                                                                                                                                                                                        |
| **`tenant_registry.yaml`**    | List of allowed tenant ids; optional **enforcement** via **`AUTH_TENANT_REGISTRY_ENFORCED=true`** so unknown `tenant_id` claims are rejected.                                                                                                                                                                                                                 |
| **Policies**                  | `configs/rebac/policies/*.yaml` — validated with **`scripts/rebac_policy.py validate`**. Change policies when you add relations or tenants that must be governed consistently.                                                                                                                                                                                |
| **Keycloak**                  | Must issue **`tenant_id`** / **`tenant`** on tokens for users who should live in a non-default tenant. The stock seed script reconciles **hardcoded** claim mappers from **`AUTH_REBAC_DEFAULT_TENANT_ID`** (everyone gets the same tenant). **Multiple tenants** usually need **User Attribute** or **Group** mappers (or separate clients/realms) — see §4. |

### 2. Add a tenant manifest (Kamiwaza repo)

1. Copy **`tenant-manifest-acme-lab.yaml`** from this directory into the Kamiwaza tree as **`configs/rebac/tenants/acme-lab.yaml`** (or use it as a template and change `tenant:` / tuples).
2. Use **`${TENANT_ID}`** in tuple strings where you want the manifest’s **`tenant:`** value substituted at parse time.
3. If you changed **policy** files, run from the Kamiwaza repo:

```bash
PYTHONPATH=. python scripts/rebac_policy.py validate configs/rebac/policies
```

### 3. Register the tenant id

Merge **`tenant-registry-snippet.yaml`** into **`configs/rebac/tenant_registry.yaml`** in the **Kamiwaza** repo (keep your real `__default__` entry and add rows like **`acme-lab`**).

To **enforce** the registry (reject JWTs whose `tenant_id` is not listed), merge **`tenant-registry-enforcement-snippet.yaml`** into Deploy **`cluster/values/overrides.yaml`** and re-sync Helm. Until the updated registry file exists **inside the running image** (or you set **`AUTH_TENANT_REGISTRY_PATH`** to a mounted file), enforcement will still read whatever registry is on disk at **`KAMIWAZA_ROOT/configs/rebac/tenant_registry.yaml`** — typically **`/app/configs/rebac/tenant_registry.yaml`** in the container.

### 4. Keycloak — `tenant_id` on the JWT

**Lab / single-tenant:** `scripts/seed_keycloak_users.py` reconciles **OIDC hardcoded claim** mappers for **`tenant_id`** and **`tenant`** using **`AUTH_REBAC_DEFAULT_TENANT_ID`** (see **`core.scheduler.rebac.defaultTenantId`** in Helm). All users get that tenant.

**Multiple tenants:** configure the **kamiwaza** Keycloak client so each user receives the correct **`tenant_id`** (and **`tenant`**) — for example:

- **User attribute mapper:** map a user attribute `tenant_id` into token claims `tenant_id` and `tenant`, or
- **Group mapper:** map group membership to a claim your auth layer expects.

Align claim names with what the API validates (**`tenant_id`** / **`tenant`** are the names the seed script uses). After changes, have users re-login so tokens refresh.

### 5. Apply bootstrap tuples (live database)

**Dry-run plan (Kamiwaza repo, auth DB reachable):**

```bash
# Example: from laptop with DATABASE_URL pointing at core/auth Postgres
export AUTH_DATABASE_URL='postgresql+psycopg2://...'
PYTHONPATH=. python scripts/rebac_tenant.py plan configs/rebac/tenants/acme-lab.yaml
```

**Apply:**

```bash
PYTHONPATH=. python scripts/rebac_tenant.py bootstrap configs/rebac/tenants/acme-lab.yaml
# Optional explicit id:  ... bootstrap ... --tenant acme-lab
```

**Against an in-cluster scheduler** (manifest must exist **inside** the pod — e.g. image rebuilt with your `configs/rebac`, or **`kubectl cp`** your YAML to `/tmp` first):

```bash
kubectl cp ./tenant-manifest-acme-lab.yaml kamiwaza/$(kubectl -n kamiwaza get pod -l app.kubernetes.io/name=core-scheduler -o jsonpath='{.items[0].metadata.name}'):/tmp/acme-lab.yaml -c core
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- \
  python /app/scripts/rebac_tenant.py plan /tmp/acme-lab.yaml
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- \
  python /app/scripts/rebac_tenant.py bootstrap /tmp/acme-lab.yaml
```

**Drift check** (non-zero exit if store ≠ manifest):

```bash
PYTHONPATH=. python scripts/rebac_tenant.py diff configs/rebac/tenants/acme-lab.yaml
```

### 6. HTTP APIs (admin)

With an **admin** session, the platform exposes tuple operations consistent with the CLI parser, for example:

- List: **`GET /api/auth/tuples?tenant=<id>`**
- Diff manifest body: **`POST /api/auth/tuples/diff`**
- Revoke: **`POST /api/auth/tuples/revoke`**
- Export audit-style events: **`GET /api/auth/tuples/export?tenant=<id>`**

Exact OpenAPI details live under **`/api/docs`** on a running cluster. Longer operator notes: **`docs-internal/topics/auth/setup.md`** in the Kamiwaza repo.

### 7. Rebuild or mount config changes

Edits to **`configs/rebac/tenant_registry.yaml`** or new files under **`configs/rebac/tenants/`** only affect a **running** cluster after:

- a **new application image** that includes them, or
- a **volume mount** (e.g. ConfigMap) plus **`AUTH_TENANT_REGISTRY_PATH`** when using a custom registry path.

Plan CI/CD accordingly — treat manifests like code (review + `rebac_policy.py` + optional `rebac_tenant.py diff` in pipelines).

---

## Deeper reading

- Deploy Helmfile hook: **`cluster/helmfile.yaml.gotmpl`** (`KAMIWAZA_REBAC_ENABLED` → **`values/kamiwaza-rebac.yaml`**).
- Core chart defaults: **`charts/core/values.yaml`** (`rebac`, `scheduler.rebac`).
- Kamiwaza: **`docs-internal/security/auth-operator-guide.md`**, **`docs-internal/topics/auth/setup.md`** (ReBAC CLI, registry enforcement, APIs).
- Kamiwaza scripts: **`scripts/rebac_tenant.py`**, **`scripts/rebac_policy.py`**; bootstrap code **`kamiwaza/services/auth/bootstrap.py`**; registry **`kamiwaza/services/authz/tenant_registry.py`**.

## Files

| File                                           | Purpose                                                                                             |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **`core-values-snippet.yaml`**                 | Deploy umbrella **`core:`** — enable **`rebac`** + **`scheduler.rebac`**.                           |
| **`tenant-manifest-acme-lab.yaml`**            | Example **bootstrap manifest** for tenant `acme-lab` (copy into Kamiwaza `configs/rebac/tenants/`). |
| **`tenant-registry-snippet.yaml`**             | Example **`tenant_registry.yaml`** fragment (merge in Kamiwaza `configs/rebac/`).                   |
| **`tenant-registry-enforcement-snippet.yaml`** | Deploy **`core.scheduler.extraEnv`** — set **`AUTH_TENANT_REGISTRY_ENFORCED`**.                     |
