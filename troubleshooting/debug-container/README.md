# Debug container (offline + Claude Code)

**Scenario:** get the Kamiwaza debug container — an SRE jump pod with the full
k8s toolchain (`kubectl`, `k9s`, `helm`, `stern`, …) **and Claude Code wired to
your organization's Bedrock** — onto an offline cluster from a `docker save` tar.

This runbook covers **delivery and bring-up only** (load the image, apply the
manifests, exec in). Operating Claude Code / the toolchain once you're in the
pod is the operator's job — start with the in-pod `cheatsheet` and `motd`.

**Tags:** #troubleshooting #debug-container #claude #bedrock #offline

> **The debug container image is not a public artifact.** It is distributed to
> Kamiwaza customers — ask your Kamiwaza contact for the image tar and for the
> `kamiwaza-debug-container` sources, which are the upstream of the
> `namespace-rbac.yaml` / `jump-pod.yaml` vendored here (`container/manifests/`)
> and document the full deployment patterns (jump pod, break-glass DaemonSet,
> RBAC). Everything else in this folder is readable as a pattern without it.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Cluster + `kubectl` | Configured for the target cluster context. |
| The image tar | `kamiwaza-debug-<version>-amd64.tar` (or `.tar.gz`) — request it from your Kamiwaza contact (not a public download). |
| A container runtime on the box | To `docker load` / `ctr import` the tar and (optionally) sideload it to the nodes. |
| Bedrock proxy details (optional) | Only for Claude Code: the proxy URL, region, a model id, an AWS bearer token (or IAM keys), and the proxy CA. Discover them with `bedrock_preflight.py` (Kamiwaza platform sources, `scripts/`). |

## 1. Get the tar onto the box and load it

`docker load` prints the image ref it imported — note it; it must match the
`image:` in `jump-pod.yaml` (default `:1.2.0`).

```bash
# copy the tar you were given onto the box, then:
gunzip kamiwaza-debug-1.2.0-amd64.tar.gz

# Docker:
docker load -i kamiwaza-debug-1.2.0-amd64.tar
# -> Loaded image: ghcr.io/kamiwaza-internal/kamiwaza-debug:1.2.0

# containerd (per node), if the cluster pulls from the node image store:
sudo ctr -n k8s.io image import kamiwaza-debug-1.2.0-amd64.tar
```

On a multi-node cluster with no shared registry, load the tar on **every node**
the pod might schedule to (or push it into a local registry the nodes can pull).
`jump-pod.yaml` already sets `imagePullPolicy: IfNotPresent` so the kubelet uses
the sideloaded image — just confirm its `image:` tag matches what you loaded.

## 2. Apply RBAC + the jump pod

```bash
kubectl apply -f namespace-rbac.yaml
kubectl apply -f jump-pod.yaml
kubectl -n kamiwaza-debug wait --for=condition=Ready pod/kamiwaza-debug-jump --timeout=120s
```

> RBAC is the **only** authorization boundary — anything a human or Claude Code
> can do from this pod is bounded by the `kamiwaza-debug` ClusterRole (read-all
> + exec/logs/port-forward, no resource mutation).

## 3. (Optional) Configure Claude Code for Bedrock

Skip this for a plain debug pod. To enable Claude Code, fill in the two Secret
templates in this directory from `bedrock_preflight.py` output, then:

```bash
kubectl apply -f secret-bedrock.example.yaml
kubectl apply -f secret-bedrock-ca.example.yaml      # only if the proxy uses a private CA
kubectl -n kamiwaza-debug delete pod kamiwaza-debug-jump   # restart to pick up the Secret
kubectl apply -f jump-pod.yaml
```

## 4. Exec in

```bash
kubectl -n kamiwaza-debug exec -it kamiwaza-debug-jump -- bash
```

You're now in the debug container. `claude` is pre-wired for your organization's
Bedrock (no login). From here it's over to the operator — see the in-pod
`cheatsheet` and `motd` for the toolchain.

## Verify

```bash
kubectl -n kamiwaza-debug get pod kamiwaza-debug-jump          # Running
kubectl -n kamiwaza-debug exec kamiwaza-debug-jump -- claude --version
kubectl -n kamiwaza-debug exec kamiwaza-debug-jump -- kubectl version --client
```
