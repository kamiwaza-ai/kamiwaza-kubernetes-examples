# Kaizen offline template livepatch (0.13.0 -> selected 0.13.1 fixes)

Use this after the parent Kaizen extension follow-on in
[`../README.md`](../README.md) when the customer is still on `release/0.13.0`,
cannot upgrade to `0.13.1`, and is using the offline / local catalog path.

Patch the **Kaizen catalog template on the running instance** so **new Kaizen launches only**
pick up:

- 30-day runtime lifetime
- 30-day suspended-chat retention
- the `0.13.1` Kaizen startup health-window fixes
- the `0.13.1` lower service memory reservations

## 1. Tooling — airgap-friendly (no `pip`, no `jq`)

This runbook uses only `kubectl`, `curl` (to the local port-forward), and the host
`python3` **standard library**. There is **nothing to install** — no `pip install`, no
`jq`. The one step that needs a YAML parser (step 6) runs **inside the `core-scheduler`
pod**, which already ships PyYAML, so the operator host needs no YAML library and no
internet.

> Verify the pod's PyYAML if you want: `kubectl -n kamiwaza exec deploy/core-scheduler -c core -- python -c 'import yaml; print(yaml.__version__)'`

## 2. Set variables

```bash
NS=kamiwaza
LOCAL_PORT=8443
PATCH_MAX_HOURS=720          # 30 days
PATCH_SUSPENDED_DAYS=30
WORKDIR=$(mktemp -d)
```

## 3. Port-forward the ingress service

```bash
INGRESS_SVC=$(kubectl -n "$NS" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^(traefik|istio-ingressgateway)$' | head -n1)
kubectl -n "$NS" port-forward "svc/$INGRESS_SVC" "${LOCAL_PORT}:443" >/tmp/kaizen-portforward.log 2>&1 &
PF_PID=$!
sleep 5
```

## 4. Get a token

```bash
SVC_CORE_PASS=$(kubectl -n "$NS" get secret kamiwaza-user-svc-core -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk "https://127.0.0.1:${LOCAL_PORT}/api/auth/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'username=svc-core' --data-urlencode "password=${SVC_CORE_PASS}" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')
```

## 5. Export the current Kaizen template and back it up

```bash
curl -sk "https://127.0.0.1:${LOCAL_PORT}/api/apps/app_templates" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c '
import sys, json
items = json.load(sys.stdin)
m = [t for t in items if t.get("name") == "Kaizen" and t.get("source_type") == "kamiwaza"]
if len(m) != 1:
    raise SystemExit("Expected exactly one Kaizen template, found %d" % len(m))
json.dump(m[0], sys.stdout)
' > "$WORKDIR/kaizen-template.json"

cp "$WORKDIR/kaizen-template.json" /tmp/kaizen-template.backup.json
TEMPLATE_ID=$(python3 -c 'import sys, json; print(json.load(open(sys.argv[1]))["id"])' "$WORKDIR/kaizen-template.json")
```

## 6. Build the patch payload (runs inside the pod — PyYAML is there, not on the host)

The Kaizen template embeds a docker-compose document in its `compose_yml` field, so this
step needs a YAML parser. Instead of installing one on the host, pipe the script into the
`core-scheduler` pod's Python (which has PyYAML) and pass the template in via an env var.
No `pip`, no internet.

```bash
TPL_B64=$(base64 < "$WORKDIR/kaizen-template.json" | tr -d '\n')

kubectl -n "$NS" exec -i deploy/core-scheduler -c core -- \
  env TPL_B64="$TPL_B64" MAX="$PATCH_MAX_HOURS" DAYS="$PATCH_SUSPENDED_DAYS" python - \
  > "$WORKDIR/kaizen-template.patch.json" <<'PY'
import base64, json, os, sys
import yaml  # PyYAML ships in the platform image — no host install needed

tpl = json.loads(base64.b64decode(os.environ["TPL_B64"]))
max_hours, suspended_days = os.environ["MAX"], os.environ["DAYS"]

doc = yaml.safe_load(tpl["compose_yml"])
svc = doc["services"]

env_defaults = dict(tpl.get("env_defaults") or {})
env_defaults["SANDBOX_MAX_LIFETIME_HOURS"] = str(max_hours)
env_defaults["SUSPENDED_CONVERSATION_CLEANUP_DAYS"] = str(suspended_days)

svc["backend"]["environment"]["SANDBOX_MAX_LIFETIME_HOURS"] = f"${{SANDBOX_MAX_LIFETIME_HOURS:-{max_hours}}}"
svc["backend"]["environment"]["SUSPENDED_CONVERSATION_CLEANUP_DAYS"] = f"${{SUSPENDED_CONVERSATION_CLEANUP_DAYS:-{suspended_days}}}"

svc["backend"]["healthcheck"]["timeout"] = "15s"
svc["backend"]["healthcheck"]["retries"] = 90
svc["backend"]["healthcheck"]["start_period"] = "900s"

svc["frontend"]["healthcheck"]["timeout"] = "20s"
svc["frontend"]["healthcheck"]["retries"] = 240
svc["frontend"]["healthcheck"]["start_period"] = "2400s"

svc["postgres"]["deploy"]["resources"]["reservations"]["memory"] = "64M"
svc["sandbox-controller"]["deploy"]["resources"]["reservations"]["memory"] = "64M"
svc["backend"]["deploy"]["resources"]["reservations"]["memory"] = "64M"

patch = {
    "env_defaults": env_defaults,
    "compose_yml": yaml.safe_dump(doc, sort_keys=False, default_flow_style=False),
}
sys.stdout.write(json.dumps(patch))
PY
```

## 7. Apply the patch

```bash
curl -sk -X PUT "https://127.0.0.1:${LOCAL_PORT}/api/apps/app_templates/${TEMPLATE_ID}" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data @"$WORKDIR/kaizen-template.patch.json" \
  | python3 -c 'import sys, json; d = json.load(sys.stdin); print(json.dumps({"id": d.get("id"), "name": d.get("name")}))'
```

## 8. Verify it

```bash
curl -sk "https://127.0.0.1:${LOCAL_PORT}/api/apps/app_templates/${TEMPLATE_ID}" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
e = d.get("env_defaults") or {}
print(json.dumps({
    "name": d.get("name"),
    "env_defaults": {
        "SANDBOX_MAX_LIFETIME_HOURS": e.get("SANDBOX_MAX_LIFETIME_HOURS"),
        "SUSPENDED_CONVERSATION_CLEANUP_DAYS": e.get("SUSPENDED_CONVERSATION_CLEANUP_DAYS"),
    },
}, indent=2))'
```

You should see:

```json
{
  "name": "Kaizen",
  "env_defaults": {
    "SANDBOX_MAX_LIFETIME_HOURS": "720",
    "SUSPENDED_CONVERSATION_CLEANUP_DAYS": "30"
  }
}
```

## 9. Stop the port-forward

```bash
kill "$PF_PID"
```
