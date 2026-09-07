# Tomo shared-workroom isolation

Deploy the real Tomo application from the Kamiwaza application catalog, then prove that two tenants share the main platform and its published models without sharing private agents, conversations, files, or credentials.

**Tags:** #multi-tenancy #tomo #rebac #workrooms #models

The current catalog identifier is `kaizen`; the displayed product name may be Tomo or Kaizen depending on the selected Kamiwaza release. Always use the template and image digests shipped with that release.

## Architecture

- One `KamiwazaPlatform` provides authentication, ReBAC, the model catalog, and model serving.
- One catalog-deployed Tomo application serves all authorized users.
- Tenant identity comes from the authenticated `tenant_id` and `tenant` claims.
- Workroom membership controls shared Tomo resources inside a tenant.
- Kubernetes contains the real generated `KamiwazaExtension` and subordinate `ModelDeployment` resources; users do not hand-author either object for this workflow.

## Prerequisites

1. A Full, auth-enabled platform with ReBAC enabled and community fallback disabled. The [operator quickstart](../../operator/quickstart/) provides this posture.
2. At least one Ready model published through `KamiwazaPlatform.spec.models`. The quickstart publishes `tinyllama`; production environments should use the release-approved model set.
3. Tomo present in the application catalog for the selected release.
4. Three test identities:
   - Tenant A owner
   - Tenant A collaborator
   - Tenant B user
5. The identity provider issues matching `tenant_id` and `tenant` claims. The two Tenant A users receive the same value; the Tenant B user receives a different value.

Register both tenant IDs and configure claim mapping with the [ReBAC tenant registry fragments](../../security/rebac/#tenants), then verify registry enforcement. Relationship edges are no longer bootstrapped by CLI: grant them with the [plan, diff, apply workflow](../../security/rebac/) in that same directory, which previews every change and reports which producers own each edge before anything is written. Do not encode tenant membership in Kubernetes namespace names for this scenario.

## 1. Verify the main platform and shared model

The commands use the dedicated example namespace:

```bash
kubectl -n kamiwaza-examples wait \
  --for=condition=Ready kamiwazaplatform/kamiwaza \
  --timeout=45m
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.models[*]}{.name}{"\t"}{.phase}{"\t"}{.deploymentId}{"\n"}{end}'
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io
```

Require at least one Ready model. `ModelDeployment` is inspection-only for tenant users; desired model intent remains on the main platform.

## 2. Verify tenant claims before deploying Tomo

Have each test user sign in and inspect the identity endpoint or decoded access-token claims through the approved administrative tooling. Require:

| User                  | `tenant_id`        | `tenant`                |
| --------------------- | ------------------ | ----------------------- |
| Tenant A owner        | Tenant A stable ID | Same Tenant A stable ID |
| Tenant A collaborator | Tenant A stable ID | Same Tenant A stable ID |
| Tenant B user         | Tenant B stable ID | Same Tenant B stable ID |

Stop if either claim is absent or the two claims disagree. Re-login after changing identity-provider mappers so the test does not use stale tokens.

## 3. Deploy Tomo from the shipped catalog

Sign in as an authorized platform application administrator:

1. Open **App Garden** in the Kamiwaza UI.
2. Refresh or synchronize the shipped catalog.
3. Select **Tomo**. On releases that still expose the catalog identifier, select `kaizen`.
4. Review the release version, image digests, required storage, sandbox capability, and environment settings.
5. Keep authentication enabled and TLS verification enabled.
6. Deploy and wait for the application status to become Running.

Do not replace this step with a hand-written demonstration extension. The platform renders the release's actual Tomo Compose/template contract into its `KamiwazaExtension` resource.

Find the generated resource without assuming its generated name or installation namespace:

```bash
kubectl get kamiwazaextensions.extensions.kamiwaza.io -A \
  -l extensions.kamiwaza.io/name=kaizen

TOMO_NAMESPACE="$(kubectl get kamiwazaextensions.extensions.kamiwaza.io -A \
  -l extensions.kamiwaza.io/name=kaizen \
  -o jsonpath='{.items[0].metadata.namespace}')"
TOMO_EXTENSION="$(kubectl get kamiwazaextensions.extensions.kamiwaza.io -A \
  -l extensions.kamiwaza.io/name=kaizen \
  -o jsonpath='{.items[0].metadata.name}')"
test -n "${TOMO_NAMESPACE}"
test -n "${TOMO_EXTENSION}"
kubectl -n "${TOMO_NAMESPACE}" wait \
  --for=condition=Ready \
  "kamiwazaextension/${TOMO_EXTENSION}" \
  --timeout=15m
```

Inspect names and status only; do not print Secret data:

```bash
kubectl -n "${TOMO_NAMESPACE}" get kamiwazaextension "${TOMO_EXTENSION}" \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,VERSION:.spec.extensionRef.version,PHASE:.status.phase
kubectl -n "${TOMO_NAMESPACE}" get deployment,statefulset,service,pvc \
  -l "app.kubernetes.io/instance=${TOMO_EXTENSION}"
```

## 4. Prove private tenant isolation

As the Tenant A owner:

1. Open Tomo.
2. Create a private agent named `tenant-a-private-agent` using the Ready shared model.
3. Start a private conversation and add a file named `tenant-a-private.txt`.
4. Record the agent, conversation, and file identifiers without recording tokens or file content.

As the Tenant B user in a separate browser profile:

1. Open the same Tomo deployment.
2. Confirm `tenant-a-private-agent`, its conversation, and `tenant-a-private.txt` are absent from list and search results.
3. Attempt direct navigation to each recorded Tenant A identifier.
4. Require a not-found or authorization-denied result. Any returned resource content is a failure.
5. Create `tenant-b-private-agent` and verify the Tenant A owner cannot see it.

## 5. Prove same-tenant workroom collaboration

As the Tenant A owner:

1. Create a shared workroom.
2. Add the Tenant A collaborator through the supported workroom membership flow.
3. Create a workroom-scoped agent that uses the same shared model.
4. Start a conversation and publish `shared-check.txt` to Workroom Files.

As the Tenant A collaborator:

1. Open the shared workroom.
2. Confirm the workroom agent, conversation, and `shared-check.txt` are visible.
3. Send a new turn and confirm the completed response reports the same runtime model attribution expected by the platform.
4. Update `shared-check.txt`; confirm the owner sees the updated canonical Workroom File.

As the Tenant B user, verify that the workroom and all four resources remain unavailable.

## 6. Verify model and credential boundaries

- Both tenants may use only models allowed by platform/runtime authorization.
- Neither tenant creates or patches `ModelDeployment`.
- A workroom collaborator cannot use creator-private model or connector credentials. Use a workroom-shared credential binding or remove the private dependency.
- Private Secret values never appear in `KamiwazaExtension`, status, Events, logs, or this evidence record.
- Tenant isolation is enforced by authenticated tenant/workroom context and ReBAC, not by trusting client-supplied headers.

## 7. Capture operator evidence

```bash
kubectl -n "${TOMO_NAMESPACE}" get kamiwazaextension "${TOMO_EXTENSION}" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=PHASE:.status.phase,CURRENT:.status.currentVersion,OBSERVED:.status.observedGeneration
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io
```

The evidence must show one healthy main platform, the real Tomo extension Running, shared models Ready, same-tenant collaboration working, and cross-tenant direct access denied.

## Cleanup

Delete test workrooms, agents, conversations, and files through Tomo first. Remove the Tomo catalog deployment through App Garden only when no other user depends on it. Let the extension finalizer complete; do not delete generated Deployments, PVCs, or the `KamiwazaExtension` directly as a shortcut.
