#!/usr/bin/env bash
# Deploy the extension-trust mutating admission webhook — the DYNAMIC, extension-agnostic
# way to make EVERY Kamiwaza extension workload trust a corporate CA, with no per-extension
# patching. It covers:
#   - declared extension service pods (apps, tools, MCP servers) in kamiwaza-extensions
#     (matched by label extensions.kamiwaza.io/deployment-id), and
#   - spawned sandbox pods in kamiwaza-sandboxes (matched by label kamiwaza.io/sandbox=true).
#
# It is NOT specific to Kaizen or to sandboxes — any extension that runs pods carrying those
# labels is covered automatically, including extensions deployed after the webhook.
#
# What it creates (config-only, airgap-safe — no image build, no external pulls):
#   - a long-lived self-signed serving cert (SAN = the webhook Service DNS), reused on re-run
#   - Secret  <name>-tls / ConfigMap <name>-code (the webhook server)
#   - Deployment + Service <name> (runs the server on an in-cluster python image)
#   - MutatingWebhookConfiguration with TWO rules (declared-extension + sandbox)
#
# The webhook runs OUTSIDE the extension namespaces (default: kamiwaza-system) so it never
# mutates itself and is reachable by the API server. failurePolicy=Ignore => a webhook
# outage degrades to "pod without injected trust" and never blocks pod creation.
#
# Prereq: the kamiwaza-trust-bundle ConfigMap must exist in the watched namespaces
#   (build-trust-bundle-configmap.sh --include-sandboxes writes all of kamiwaza /
#    kamiwaza-system / kamiwaza-extensions / kamiwaza-sandboxes).
#
# Requires: bash, kubectl, openssl. NO docker, NO trust-manager.
#
# Usage:
#   ./deploy-extension-trust-webhook.sh                 # deploy (auto-detects a python image)
#   ./deploy-extension-trust-webhook.sh --image <ref>   # pin the runner image
#   ./deploy-extension-trust-webhook.sh --delete        # tear everything down
set -euo pipefail

NAME="extension-trust-webhook"
# Run the webhook where the API server can reach it. NOT an extension namespace —
# kamiwaza-extensions has a default-deny-style Ingress NetworkPolicy (empty podSelector)
# that blocks the API server from calling the webhook, and with failurePolicy=Ignore that
# fails silently (no injection). kamiwaza-system is permissive (no NetworkPolicies).
WEBHOOK_NS="${WEBHOOK_NS:-kamiwaza-system}"
EXT_NS="${EXT_NS:-kamiwaza-extensions}"              # declared extension service pods
SANDBOX_NS="${SANDBOX_NS:-kamiwaza-sandboxes}"       # spawned sandbox pods
EXT_LABEL_KEY="extensions.kamiwaza.io/deployment-id" # present on declared extension pods
SANDBOX_LABEL_KEY="kamiwaza.io/sandbox"
SANDBOX_LABEL_VAL="true"
BUNDLE_CONFIGMAP="${BUNDLE_CONFIGMAP:-kamiwaza-trust-bundle}"
BUNDLE_KEY="${BUNDLE_KEY:-ca-certificates.crt}"
BUNDLE_MOUNT_PATH="${BUNDLE_MOUNT_PATH:-/etc/ssl/certs/ca-certificates.crt}"
CA_ENV_VARS="${CA_ENV_VARS:-SSL_CERT_FILE,REQUESTS_CA_BUNDLE,AWS_CA_BUNDLE,NODE_EXTRA_CA_CERTS}"
IMAGE=""
PORT=8443
CERT_DAYS=3650
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DELETE=0

err() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; }
info() { printf '\033[1m%s\033[0m\n' "$1" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
  --image)
    IMAGE="${2:?}"
    shift 2
    ;;
  --webhook-ns)
    WEBHOOK_NS="${2:?}"
    shift 2
    ;;
  --ext-ns)
    EXT_NS="${2:?}"
    shift 2
    ;;
  --sandbox-ns)
    SANDBOX_NS="${2:?}"
    shift 2
    ;;
  --delete)
    DELETE=1
    shift
    ;;
  -h | --help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    err "unknown arg: $1"
    exit 2
    ;;
  esac
done

command -v kubectl >/dev/null || {
  err "kubectl not found"
  exit 1
}
command -v openssl >/dev/null || {
  err "openssl not found"
  exit 1
}

if [ "$DELETE" -eq 1 ]; then
  info "Tearing down $NAME"
  kubectl delete mutatingwebhookconfiguration "$NAME" --ignore-not-found
  kubectl -n "$WEBHOOK_NS" delete deploy,svc,cm,secret -l "app=$NAME" --ignore-not-found
  info "Done."
  exit 0
fi

if [ -z "$IMAGE" ]; then
  IMAGE="$(kubectl -n kamiwaza get deploy core-scheduler -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
fi
[ -n "$IMAGE" ] || {
  err "could not auto-detect a runner image; pass --image <ref>"
  exit 1
}
info "Runner image: $IMAGE"
CODE_SHA="$(openssl dgst -sha256 "${SCRIPT_DIR}/extension-trust-webhook.py" | awk '{print $NF}')"

SVC_DNS="${NAME}.${WEBHOOK_NS}.svc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Idempotent cert: reuse the existing serving cert + caBundle if both are present, so re-runs
# keep a STABLE caBundle (regenerating it without rolling the pod would break TLS to the API
# server). The cert-sha pod annotation below rolls the pod whenever the cert does change.
EXISTING_CAB="$(kubectl get mutatingwebhookconfiguration "$NAME" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)"
EXISTING_CRT="$(kubectl -n "$WEBHOOK_NS" get secret "${NAME}-tls" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
if [ -n "$EXISTING_CAB" ] && [ -n "$EXISTING_CRT" ]; then
  info "Reusing existing serving cert + caBundle (stable across re-runs)"
  CABUNDLE="$EXISTING_CAB"
else
  info "Generating long-lived self-signed CA + serving cert (SAN=${SVC_DNS})"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
    -days "$CERT_DAYS" -subj "/CN=${NAME}-ca" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$WORK/tls.key" -out "$WORK/tls.csr" \
    -subj "/CN=${SVC_DNS}" >/dev/null 2>&1
  openssl x509 -req -in "$WORK/tls.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
    -days "$CERT_DAYS" -out "$WORK/tls.crt" \
    -extfile <(printf 'subjectAltName=DNS:%s,DNS:%s.cluster.local\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth' "$SVC_DNS" "$SVC_DNS") >/dev/null 2>&1
  CABUNDLE="$(base64 <"$WORK/ca.crt" | tr -d '\n')"
  kubectl -n "$WEBHOOK_NS" create secret tls "${NAME}-tls" \
    --cert="$WORK/tls.crt" --key="$WORK/tls.key" --dry-run=client -o yaml |
    kubectl label --local -f - app="$NAME" -o yaml --dry-run=client | kubectl apply -f - >/dev/null
fi
CERT_SHA="$(printf '%s' "$CABUNDLE" | openssl dgst -sha256 | awk '{print $NF}')"

info "Applying ConfigMap"
kubectl -n "$WEBHOOK_NS" create configmap "${NAME}-code" \
  --from-file="extension-trust-webhook.py=${SCRIPT_DIR}/extension-trust-webhook.py" --dry-run=client -o yaml |
  kubectl label --local -f - app="$NAME" -o yaml --dry-run=client | kubectl apply -f - >/dev/null

info "Applying Deployment + Service"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${NAME}, namespace: ${WEBHOOK_NS}, labels: {app: ${NAME}}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ${NAME}}}
  template:
    metadata:
      labels: {app: ${NAME}}
      annotations:
        ext-trust.kamiwaza.io/code-sha: "${CODE_SHA}"
        ext-trust.kamiwaza.io/cert-sha: "${CERT_SHA}"
    spec:
      automountServiceAccountToken: false
      containers:
      - name: webhook
        image: ${IMAGE}
        command: ["python", "/code/extension-trust-webhook.py"]
        env:
        - {name: BUNDLE_CONFIGMAP, value: "${BUNDLE_CONFIGMAP}"}
        - {name: BUNDLE_KEY, value: "${BUNDLE_KEY}"}
        - {name: BUNDLE_MOUNT_PATH, value: "${BUNDLE_MOUNT_PATH}"}
        - {name: CA_ENV_VARS, value: "${CA_ENV_VARS}"}
        - {name: LISTEN_PORT, value: "${PORT}"}
        ports: [{containerPort: ${PORT}}]
        readinessProbe: {httpGet: {path: /healthz, port: ${PORT}, scheme: HTTPS}, periodSeconds: 5}
        livenessProbe: {httpGet: {path: /healthz, port: ${PORT}, scheme: HTTPS}, periodSeconds: 10}
        resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
        securityContext:
          runAsNonRoot: true
          runAsUser: 65532
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: ["ALL"]}
          seccompProfile: {type: RuntimeDefault}
        volumeMounts:
        - {name: code, mountPath: /code, readOnly: true}
        - {name: tls, mountPath: /tls, readOnly: true}
      volumes:
      - {name: code, configMap: {name: ${NAME}-code}}
      - {name: tls, secret: {secretName: ${NAME}-tls}}
---
apiVersion: v1
kind: Service
metadata: {name: ${NAME}, namespace: ${WEBHOOK_NS}, labels: {app: ${NAME}}}
spec:
  selector: {app: ${NAME}}
  ports: [{port: 443, targetPort: ${PORT}}]
YAML

info "Waiting for the webhook to be Ready"
kubectl -n "$WEBHOOK_NS" rollout status deploy/"${NAME}" --timeout=150s >&2

info "Applying MutatingWebhookConfiguration (declared extension pods + sandbox pods, failurePolicy=Ignore)"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata: {name: ${NAME}, labels: {app: ${NAME}}}
webhooks:
# (1) declared extension service pods: apps, tools, MCP servers
- name: declared.${NAME}.kamiwaza.io
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Ignore
  reinvocationPolicy: IfNeeded
  timeoutSeconds: 5
  clientConfig:
    service: {name: ${NAME}, namespace: ${WEBHOOK_NS}, path: /mutate, port: 443}
    caBundle: ${CABUNDLE}
  namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ${EXT_NS}}}
  objectSelector:
    matchExpressions:
    - {key: ${EXT_LABEL_KEY}, operator: Exists}
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
    scope: Namespaced
# (2) spawned sandbox pods (Kaizen and any sandbox-spawning extension)
- name: sandbox.${NAME}.kamiwaza.io
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Ignore
  reinvocationPolicy: IfNeeded
  timeoutSeconds: 5
  clientConfig:
    service: {name: ${NAME}, namespace: ${WEBHOOK_NS}, path: /mutate, port: 443}
    caBundle: ${CABUNDLE}
  namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ${SANDBOX_NS}}}
  objectSelector:
    matchLabels: {${SANDBOX_LABEL_KEY}: "${SANDBOX_LABEL_VAL}"}
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
    scope: Namespaced
YAML

info "Done. Every NEW extension pod now mounts ${BUNDLE_CONFIGMAP} at ${BUNDLE_MOUNT_PATH} +"
info "gets the CA env (${CA_ENV_VARS}) — declared pods in ${EXT_NS} and sandbox pods in ${SANDBOX_NS}."
cat >&2 <<EOF

Prereq: ${BUNDLE_CONFIGMAP} must exist in the watched namespaces
  (build-trust-bundle-configmap.sh --include-sandboxes).
Verify: roll/recreate an extension pod (or open a Kaizen conversation), then:
  kubectl -n ${EXT_NS} get pod <pod> -o jsonpath='{range .spec.containers[*].volumeMounts[*]}{.mountPath}{"\\n"}{end}' | grep ca-certificates
Teardown: $0 --delete
EOF
