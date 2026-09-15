# Platform observability

## Purpose

Send platform OTLP logs, metrics, and traces to one administrator-approved sink and provide a small dashboard contract. The included collector is bounded test infrastructure, not a production backend.

## Grounded design

Monitoring remains external. The operator resolves a stable `sinkRef`, configures reviewed workloads, and reports the capability. It never installs, upgrades, credentials, or deletes a production collector or dashboard service.

## Prerequisites and apply

Replace `example-rwo` and `observability.example.invalid`. Reuse the [shared operator installation](../../operator/quickstart/) with this scenario's `operator-values.yaml`; it allows `External` mode and approves `scenario-collector`.

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-observability wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-observability logs job/telemetry-check
kubectl -n kw-observability logs deployment/otel-collector
```

Require accepted OTLP signals and inspect collector output for stable platform, namespace, component, and reconcile-result attributes. Any Secret value, token, endpoint credential, prompt, or user content is a failure. `dashboard.yaml` carries backend-neutral query intent; import it into an administrator-owned dashboard system after mapping metric names to the release's published telemetry contract.

## Outage and disable

Scale or withdraw the test collector through its declared Deployment to test sink outage, then reapply `collector.yaml`. Platform data and readiness must survive. Current operator status reports `ExternalTelemetryReady` after policy resolution and does not probe the sink; the failed `telemetry-check` is the observable outage gate. Treat this as a validation gap, not permission to add an operator-owned backend.

To disable export, apply a complete platform manifest with `observability.mode: Disabled` and no `sinkRef`. The platform must remain ready and remove OTLP endpoint configuration on reconcile.

## Cleanup

```bash
kubectl -n kw-observability delete job/telemetry-check kamiwazaplatform/kamiwaza deployment/otel-collector service/otel-collector configmap/otel-collector,kamiwaza-platform-dashboard
kubectl -n kw-observability get pvc
```

`RetainData` preserves platform state. Production telemetry infrastructure remains external.
