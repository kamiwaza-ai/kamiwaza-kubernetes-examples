# Metadata Catalog opt-in

## Purpose

Enable the provider-neutral Metadata Catalog capability, ingest one deterministic entity and relationship through the application API, disable workloads without deleting state, then re-enable and query the same result.

## Grounded design

Optional subsystems remain explicit in desired state. `components.metadataCatalog.enabled` selects the capability; administrator policy chooses its reviewed implementation and keeps provider products and lifecycle jobs internal.

The default adapter uses the reviewed search-backed graph. No Neo4j workload, PVC, Secret, permission, route, field, status identity, or migration object belongs in this scenario.

## Prerequisites

- StorageClass `example-rwo` and existing platform credential Secrets named in `base/platform.yaml`.
- Existing `catalog-client` bearer-token Secret for the check Jobs.
- Gateway certificate Secret `kamiwaza-gateway-tls`.
- Shared manager installed through the [operator quickstart](../quickstart/) with this scenario's `operator-values.yaml`.

Replace `catalog.example.invalid` and all environment-specific names. Runtime entities, lineage, identities, and grants are application data. Do not model them as Kubernetes custom resources.

## Enable and ingest

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k base
kubectl -n kw-metadata-catalog wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-metadata-catalog wait --for=condition=complete job/catalog-ingest --timeout=10m
kubectl -n kw-metadata-catalog wait --for=condition=complete job/catalog-query --timeout=10m
kubectl -n kw-metadata-catalog logs job/catalog-query
```

The checks use Core's public `/catalog` dataset and container contract. They never call the internal catalog provider Service or leak its schema into the example.

## Disable, retain, and re-enable

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k disabled
kubectl -n kw-metadata-catalog get pods,pvc
kubectl apply --server-side --field-manager=platform-operator-user -k base
kubectl -n kw-metadata-catalog wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-metadata-catalog delete job/catalog-query --ignore-not-found
kubectl -n kw-metadata-catalog apply -f base/catalog-checks.yaml
kubectl -n kw-metadata-catalog logs job/catalog-query
```

Disabled state removes catalog workloads and routes but retains catalog PVCs and identity. Re-enable must return the same entity and relationship. It must not bootstrap a second logical catalog.

During a catalog-only dependency outage, Metadata Catalog reports a component-specific transient wait. Application API, identity, object storage, web, and model serving continue. Recovery reuses retained state and completed lifecycle Jobs.

## Cleanup

```bash
kubectl delete -k disabled
kubectl -n kw-metadata-catalog get pvc
```

`RetainData` keeps platform and catalog state. Delete retained catalog data only through an approved application lifecycle.
