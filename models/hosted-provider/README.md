# Hosted model providers

## Purpose

Declare Bedrock, Azure AI, Google Vertex, OpenRouter, or an OpenAI-compatible endpoint through one provider-neutral `ModelDeployment` contract. Provider-specific addressing and adapter selection stay in immutable administrator policy, never tenant platform or model intent.

## Grounded design

Confluent's [connector examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/connectors) separate a common resource contract from connector-specific configuration. Kamiwaza keeps the same boundary: tenant intent selects a named provider profile and local Secret reference, while administrator policy owns the typed adapter, destination class, endpoint, and provider settings. Hosted models create no local Pod, PVC, or accelerator request.

## Provider lanes

| Directory                     | Provider profile    | Required Secret key                           | Administrator-owned settings               |
| ----------------------------- | ------------------- | --------------------------------------------- | ------------------------------------------ |
| `providers/bedrock`           | `bedrock`           | `model-provider-bedrock/credential`           | adapter, region, destination               |
| `providers/azure-ai`          | `azure-ai`          | `model-provider-azure/credential`             | adapter, endpoint, deployment, destination |
| `providers/google-vertex`     | `google-vertex`     | `model-provider-vertex/credential`            | adapter, project, location, destination    |
| `providers/openrouter`        | `openrouter`        | `model-provider-openrouter/credential`        | adapter and destination                    |
| `providers/openai-compatible` | `openai-compatible` | `model-provider-openai-compatible/credential` | adapter, endpoint, destination             |

Create the provider Secret and `hosted-check-client/token` outside Git. Configure each selected administrator profile and destination class, DNS, and `kamiwaza-gateway-tls`. Replace placeholder project, deployment, endpoint, and model identifiers. Apply one lane:

```bash
kubectl diff --server-side --field-manager=model-owner -k providers/bedrock
kubectl apply --server-side --field-manager=model-owner -k providers/bedrock
kubectl -n kw-hosted-models wait --for=condition=Ready modeldeployment/hosted-model --timeout=5m
kubectl -n kw-hosted-models logs job/hosted-provider-inference-check
kubectl -n kw-hosted-models get deploy,pvc -l serving.kamiwaza.io/deployment-id=hosted-model
```

The last command must return no local serving workload or claim. The Job retries only timeouts, throttling, and provider 5xx responses. Authentication refusal fails immediately. Output contains model attribution and finish reason, never prompt, answer, or credentials.

## Validation gap exposed by this scenario

Current `ModelDeployment` accepts provider-specific fields directly and reports `Ready=True`, reason `HostedByProvider`, after checking only that the referenced Secret key exists. This contract replaces that surface with `external.providerProfileRef`; the operator must resolve the immutable profile, verify its destination class before loading credentials, and classify real provider readiness. Ready status alone does not satisfy this scenario; the end-to-end Job remains the acceptance gate. Do not add a local fallback or imperative provider registration to hide that gap.

## Cleanup

```bash
kubectl -n kw-hosted-models delete job/hosted-provider-inference-check modeldeployment/hosted-model
```

Deletion removes projection state only. Provider credentials and remote deployments remain external.
