# Debug container (offline + Claude Code)

**Scenario:** load a customer-supplied Kamiwaza debug image into an offline
k0s cluster. Run an SRE jump pod with `kubectl`, `k9s`, `helm`, `stern`, and
optional Claude Code access through an organization-managed Bedrock endpoint.

This runbook covers image delivery, deployment, and entry into the pod. Use the
in-pod `cheatsheet` and `motd` for tool instructions.

Tags: #troubleshooting #debug-container #claude #bedrock #offline.

> The debug image is not a public artifact. Request the image archive and its
> matching release instructions from your Kamiwaza contact. Do not substitute
> an image with a similar name. The private source repository remains the
> authority for the full jump-pod and break-glass patterns.

## Prerequisites

| Requirement                      | Notes                                                                                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cluster + `kubectl`              | Configured for the target cluster context.                                                                                                                                                       |
| The image tar                    | `kamiwaza-debug-<version>-amd64.tar` (or `.tar.gz`) — request it from your Kamiwaza contact (not a public download).                                                                             |
| A container runtime on the box   | To `docker load` / `ctr import` the tar and (optionally) sideload it to the nodes.                                                                                                               |
| Bedrock proxy details (optional) | Only for Claude Code: the proxy URL, region, a model id, an AWS bearer token (or IAM keys), and the proxy CA. Discover them with `bedrock_preflight.py` (Kamiwaza platform sources, `scripts/`). |

## 1. Load the exact image

The imported image reference must match `jump-pod.yaml`. The example uses
`ghcr.io/kamiwaza-internal/kamiwaza-debug:1.2.0`.

```bash
# Keep the original archive and decompress a copy.
gzip -dk kamiwaza-debug-1.2.0-amd64.tar.gz

# Import into the k0s image store on each schedulable node.
sudo k0s ctr images import kamiwaza-debug-1.2.0-amd64.tar

# Confirm the exact reference.
sudo k0s ctr images list \
  'name==ghcr.io/kamiwaza-internal/kamiwaza-debug:1.2.0'
```

For another containerd distribution, use its supported import command. Load the
image on every node that can schedule this pod. A shared private registry is
also valid if every node can authenticate to it.

The pod uses `imagePullPolicy: IfNotPresent`. This setting does not make an
absent private image available.

## 2. Apply RBAC and the jump pod

```bash
kubectl apply -f troubleshooting/debug-container/namespace-rbac.yaml
kubectl apply -f troubleshooting/debug-container/jump-pod.yaml
kubectl -n kamiwaza-debug wait \
  --for=condition=Ready pod/kamiwaza-debug-jump \
  --timeout=120s
```

> This pod has a high-trust SRE role. The role can read Secret data and open
> exec sessions in every namespace. An exec session can change workload state
> without a Kubernetes API mutation. Bind the role only to a short-lived,
> administrator-controlled identity. Delete the resources after the incident.

## 3. Configure Claude Code for Bedrock (optional)

Skip this section for a plain debug pod. Never put real credentials in the
repository. Copy each template to a protected temporary file, replace every
placeholder, and apply the temporary file.

```bash
install -m 0600 troubleshooting/debug-container/secret-bedrock.example.yaml \
  /tmp/kamiwaza-debug-bedrock.yaml
install -m 0600 troubleshooting/debug-container/secret-bedrock-ca.example.yaml \
  /tmp/kamiwaza-debug-bedrock-ca.yaml

# Edit both temporary files, then apply only the required files.
kubectl apply -f /tmp/kamiwaza-debug-bedrock.yaml
kubectl apply -f /tmp/kamiwaza-debug-bedrock-ca.yaml
kubectl -n kamiwaza-debug delete pod kamiwaza-debug-jump
kubectl apply -f troubleshooting/debug-container/jump-pod.yaml

rm -f /tmp/kamiwaza-debug-bedrock.yaml \
  /tmp/kamiwaza-debug-bedrock-ca.yaml
```

## 4. Exec in

```bash
kubectl -n kamiwaza-debug exec -it kamiwaza-debug-jump -- bash
```

The image configures Claude Code for Bedrock. The Bedrock proxy and credentials
remain administrator-owned prerequisites.

## Verify

```bash
kubectl -n kamiwaza-debug get pod kamiwaza-debug-jump
kubectl -n kamiwaza-debug exec kamiwaza-debug-jump -- claude --version
kubectl -n kamiwaza-debug exec kamiwaza-debug-jump -- kubectl version --client
kubectl auth can-i --as=system:serviceaccount:kamiwaza-debug:kamiwaza-debug \
  get secrets --all-namespaces
kubectl auth can-i --as=system:serviceaccount:kamiwaza-debug:kamiwaza-debug \
  create deployments --all-namespaces
```

Expected authorization results are `yes` for Secret reads and `no` for
Deployment creation.

## Cleanup

Remove the high-trust role and namespace when the incident ends:

```bash
kubectl delete -f troubleshooting/debug-container/jump-pod.yaml
kubectl delete -f troubleshooting/debug-container/namespace-rbac.yaml
```

Delete the imported image from each node when local retention is not required:

```bash
sudo k0s ctr images rm \
  ghcr.io/kamiwaza-internal/kamiwaza-debug:1.2.0
```

## Validation evidence

On 2026-09-16, the exact image was exported, removed from the k0s image store,
and imported with the documented `k0s ctr` command. The pod event confirmed
that the sideloaded image was already present. The pod reached Ready with zero
restarts. `claude --version` returned `2.1.161`, and `kubectl version --client`
returned `v1.34.8`. The process ran as UID and GID `65532`. Writes succeeded in
`/tmp` and failed on the read-only root filesystem.

Live authorization checks allowed Secret reads and refused Deployment creation.
The namespace enforced the restricted Pod Security Standard and denied ingress
to the jump pod. No Bedrock request was made because the organization-owned
proxy, credentials, and model selection were not available.
