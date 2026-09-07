# Preview and adopt an existing installation

Transfer explicitly selected resources from a supported Helmfile-managed Kamiwaza installation to the operator without changing retained identities.

**Tags:** #operator #migration #adoption #helmfile

Adoption is not a generic import. The current release supports only the exact `1.1.0` source revision published in its compatibility artifact. The `1.2.0` source remains blocked because its active KubeRay state has no published migration evidence.

The commands use `kamiwaza-examples` so a rehearsal cannot target a default
`kamiwaza` installation accidentally. Replace it only after selecting and
recording the reviewed source namespace.

## Safety boundary

Preview is read-only. Explicit transfer requires all of these controls:

1. The exact source version and revision are supported by the installed operator's compatibility artifact.
2. Immutable admin policy sets `operations.adoptionAllowed: true`.
3. `spec.adoption.allowResources` names every resource that may transfer.
4. `spec.adoption.allowFieldManagers` names every existing server-side-apply manager that may transfer.
5. Explicit mode carries the latest unchanged preview revision.

Do not stop Helmfile reconciliation until preview is compatible and the handoff window begins. Do not run the legacy extension controller and shared manager against the same extension fields.

## 1. Freeze and inspect the source contract

From the reviewed operator release:

```bash
cat dist/compatibility.json
kubectl -n kamiwaza-examples get configmap,secret,service,pvc,deployment,statefulset,job \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid,RESOURCE_VERSION:.metadata.resourceVersion
```

Capture PVC UIDs, Secret content hashes through an approved non-printing procedure, service endpoints, source controller Deployments, and platform smoke results. Never print Secret data into the migration record.

At least one allowlisted source anchor must carry both `platform.kamiwaza.io/source-version` and `platform.kamiwaza.io/source-revision` annotations. Conflicting or absent provenance blocks preview.

## 2. Enable adoption authority

Merge this setting into the complete, reviewed operator values used for the target manager:

```yaml
adminPolicy:
  operations:
    adoptionAllowed: true
```

Upgrade the manager installation through the administrator-owned release process. Do not apply a partial Helm values file that would reset existing policy.

## 3. Create platform intent

Create a `KamiwazaPlatform` using the same storage, domain, dependency, Secret, and image contract as the live installation. Set its adoption block from `adoption-preview-patch.yaml` before the first apply.

Replace the checked-in `ConfigMap/core` entry with the complete resource identity allowlist. An intentionally incomplete or incorrect identity must block safely; it is not discovered automatically.

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type=merge \
  --patch-file adoption-preview-patch.yaml
```

If the root does not exist yet, merge the patch under `spec.adoption` into the full platform manifest and apply that manifest instead.

## 4. Review the preview

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.status.adoption}'
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
```

Require:

- A non-empty 64-character `status.adoption.inventoryRevision`.
- The expected source version and exact source revision.
- Every allowlisted identity classified and fingerprinted.
- No missing, changed, forbidden, unsupported, immutable-field-conflict, or unapproved-manager entry.
- No PVC UID, Secret data, endpoint, or serving-state change during repeated previews.

## 5. Perform explicit transfer

Read the current preview revision immediately before transfer:

```bash
ADOPTION_REVISION="$(kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.status.adoption.inventoryRevision}')"
test "${#ADOPTION_REVISION}" -eq 64
```

Stop the exact legacy controller only at the reviewed handoff point. Then bind Explicit mode to the current preview:

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type=merge \
  --patch "{\"spec\":{\"adoption\":{\"mode\":\"Explicit\",\"inventoryRevision\":\"${ADOPTION_REVISION}\"}}}"
```

This merge preserves the checked-in resource and field-manager allowlists. If any source object changed after preview, the operator must remain Blocked and require a new Preview.

## 6. Verify the handoff

- Platform status reaches Ready at `1.3.0` only after the supported migration graph completes.
- PVC UIDs, Secret hashes, certificate identity, database contents, and public endpoints match the baseline.
- Managed fields transfer only for listed objects and approved field managers.
- Independent `KamiwazaExtension` roots keep their status and finalizers.
- The legacy controller remains stopped after the shared manager is authoritative.

A blocked or failed transfer leaves serving resources in place. Correct policy, scope, or inventory conflicts; return to Preview; obtain a new revision. Never edit status or force ownership globally.
