# GitOps self-service

## Purpose

Use Flux or Argo CD as an external reconciliation prerequisite. Both variants install CRDs and operator chart, apply immutable administrator policy, then reconcile one tenant platform. No GitOps type, controller detection, or provider configuration enters operator APIs.

## Grounded design

Confluent's [co-deployment examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/co-deployments) show controller-specific orchestration outside the managed custom resources. Kamiwaza keeps one provider-neutral desired-state tree. Thin Flux and Argo CD wrappers own only source retrieval, ordering, drift repair, health, and prune behavior.

## Authority

- Platform administrators own GitOps projects, source credentials, operator chart, CRDs, cluster RBAC, manager namespace, and `operator-values.yaml` content embedded in `desired-state/admin/helmrelease.yaml`.
- Tenant repositories own only approved namespaced objects under `desired-state/tenant/`.
- GitOps controller ServiceAccounts need only the permissions of their assigned project. Do not give tenant reconciliation CRD, ClusterRole, administrator-policy, or manager-namespace writes.
- Existing Secrets `platform-operator-repository`, `registry-pull`, registry credentials, and platform credentials remain controller or administrator integrations. No value appears here.

## Immutable source gate

Operator source is pinned to `ac52a6116f686f94f11c0895bcaea2c01b224d12`. Examples source is pinned to `800dfe01113c5d642572aaa0c37fef0ebf337fba`, the parent of this uncommitted work. That commit intentionally does not contain this new path, so reconciliation fails closed until these files are reviewed and later committed. After that commit exists on the remote, replace both examples revisions with its full 40-character commit ID in one reviewed change. Never substitute a branch, `HEAD`, floating chart tag, or mutable image tag.

This gate is unavoidable while honoring the current no-commit instruction. It prevents a seemingly runnable GitOps sample from silently tracking mutable work.

## Flux

Install Flux externally. Configure its existing repository Secret, then apply `flux/` once through the administrator bootstrap repository. `kamiwaza-operator` waits for the pinned HelmRelease before `kamiwaza-tenant` starts.

```bash
kubectl apply --server-side --field-manager=gitops-bootstrap -k flux
flux reconcile source git kamiwaza-examples --with-source
flux get kustomizations
kubectl -n kw-gitops logs job/desired-state-check
```

## Argo CD

Install Argo CD externally. Configure two projects and repository access first. Apply `argo-cd/` from an administrator-owned root Application. Sync waves put operator before tenant; project policy must enforce that tenant Application cannot target cluster-scoped resources or `kamiwaza-platform-system`.

```bash
kubectl apply --server-side --field-manager=gitops-bootstrap -k argo-cd
argocd app wait kamiwaza-platform-operator --health --sync
argocd app wait kamiwaza-tenant --health --sync
kubectl -n kw-gitops logs job/desired-state-check
```

## Drift, policy, and no-op checks

After healthy sync, change `spec.displayName` with a different field manager in a disposable cluster. GitOps must restore the Git value without forcing fields owned by the platform operator. Commit an unapproved domain on a test branch; the administrator policy must reject it and the GitOps application must remain degraded with the platform's cause-specific condition. Do not remove finalizers or force-conflict adoption.

Two consecutive reconciliations at the same source revisions must produce no object writes, rollout, generation change, or new rotation. Resume a suspended GitOps controller and require normal level-based convergence.

## Prune and cleanup

The platform declares `RetainData`. Pruning waits for normal platform finalization and leaves retained PVCs. External Gateway, certificate, registry, GitOps controllers, source credentials, and administrator-supplied Secrets are never in tenant prune scope.

```bash
flux suspend kustomization kamiwaza-tenant
kubectl -n kw-gitops get pvc
```

Delete desired state only through a reviewed Git change. Never use orphan, force, or finalizer-removal options to accelerate cleanup.
