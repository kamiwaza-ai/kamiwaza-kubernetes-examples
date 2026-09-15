# Hosted model providers

## Purpose

Declare Bedrock, Azure AI, Google Vertex, OpenRouter, or an OpenAI-compatible endpoint through the same external `ModelDeployment` contract. Provider-specific addressing never enters `KamiwazaPlatform`.

## Grounded design

Confluent's [connector examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/connectors) separate a common resource contract from connector-specific configuration. Kamiwaza uses the same small-overlay pattern, but credentials remain exact-name Secret references and hosted models create no local Pod, PVC, or accelerator request.

## Provider lanes

| Directory                     | Required Secret key                           | Required public fields      |
| ----------------------------- | --------------------------------------------- | --------------------------- |
| `providers/bedrock`           | `model-provider-bedrock/credential`           | `region`                    |
| `providers/azure-ai`          | `model-provider-azure/credential`             | `endpointURL`, `deployment` |
| `providers/google-vertex`     | `model-provider-vertex/credential`            | `project`, `location`       |
| `providers/openrouter`        | `model-provider-openrouter/credential`        | none                        |
| `providers/openai-compatible` | `model-provider-openai-compatible/credential` | `endpointURL`               |

Create the provider Secret and `hosted-check-client/token` outside Git. Configure DNS and `kamiwaza-gateway-tls` for `hosted-models.example.invalid`. Replace placeholder project, deployment, endpoint, and model identifiers. Apply one lane:

```bash
kubectl diff --server-side --field-manager=model-owner -k providers/bedrock
kubectl apply --server-side --field-manager=model-owner -k providers/bedrock
kubectl -n kw-hosted-models wait --for=condition=Ready modeldeployment/hosted-model --timeout=5m
kubectl -n kw-hosted-models logs job/hosted-provider-inference-check
kubectl -n kw-hosted-models get deploy,pvc -l serving.kamiwaza.io/deployment-id=hosted-model
```

The last command must return no local serving workload or claim. The Job retries only timeouts, throttling, and provider 5xx responses. Authentication refusal fails immediately. Output contains model attribution and finish reason, never prompt, answer, or credentials.

## Validation gap exposed by this scenario

Current `ModelDeployment` reconciliation reports `Ready=True`, reason `HostedByProvider`, after checking only that the referenced Secret key exists. It does not call the provider or classify malformed responses, authentication refusal, throttling, or outages. Therefore Ready status alone does not satisfy this scenario; the end-to-end Job is the acceptance gate. Do not add a local fallback or imperative provider registration to hide that gap.

## Cleanup

```bash
kubectl -n kw-hosted-models delete job/hosted-provider-inference-check modeldeployment/hosted-model
```

Deletion removes projection state only. Provider credentials and remote deployments remain external.
