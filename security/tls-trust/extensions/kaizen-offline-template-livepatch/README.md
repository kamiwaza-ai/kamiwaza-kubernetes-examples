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

## 1. Install PyYAML if needed

```bash
python3 -m pip install pyyaml
```

## 2. Set variables

```bash
NS=kamiwaza
LOCAL_PORT=8443
PATCH_MAX_HOURS=720
PATCH_SUSPENDED_DAYS=30
WORKDIR=$(mktemp -d)
```

## 3. Confirm this is the offline/local-catalog case

```bash
kubectl -n "$NS" get cm core-config -o jsonpath='{.data.KAMIWAZA_EXTENSION_STAGE}{"\n"}'
```

This should print:

```text
LOCAL
```

## 4. Port-forward the ingress service

```bash
INGRESS_SVC=$(kubectl -n "$NS" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^(traefik|istio-ingressgateway)$' | head -n1)
kubectl -n "$NS" port-forward "svc/$INGRESS_SVC" "${LOCAL_PORT}:443" >/tmp/kaizen-portforward.log 2>&1 &
PF_PID=$!
sleep 5
```

## 5. Get a token

```bash
SVC_CORE_PASS=$(kubectl -n "$NS" get secret kamiwaza-user-svc-core -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk "https://127.0.0.1:${LOCAL_PORT}/api/auth/token" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'username=svc-core' --data-urlencode "password=${SVC_CORE_PASS}" | jq -r '.access_token')
```

## 6. Export the current Kaizen template and back it up

```bash
curl -sk "https://127.0.0.1:${LOCAL_PORT}/api/apps/app_templates" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '[.[] | select(.name=="Kaizen" and .source_type=="kamiwaza")] | if length == 1 then .[0] else error("Expected exactly one Kaizen template") end' \
  > "$WORKDIR/kaizen-template.json"

cp "$WORKDIR/kaizen-template.json" /tmp/kaizen-template.backup.json
TEMPLATE_ID=$(jq -r '.id' "$WORKDIR/kaizen-template.json")
```

## 7. Build the patch payload

```bash
python3 - "$WORKDIR/kaizen-template.json" "$WORKDIR/kaizen-template.patch.json" "$PATCH_MAX_HOURS" "$PATCH_SUSPENDED_DAYS" <<'PY'
import json
import sys
import yaml

src, dst, max_hours, suspended_days = sys.argv[1:5]

with open(src, "r", encoding="utf-8") as f:
    tpl = json.load(f)

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

with open(dst, "w", encoding="utf-8") as f:
    json.dump(patch, f)
PY
```

## 8. Apply the patch

```bash
curl -sk -X PUT "https://127.0.0.1:${LOCAL_PORT}/api/apps/app_templates/${TEMPLATE_ID}" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data @"$WORKDIR/kaizen-template.patch.json" \
  | jq '{id, name}'
```

## 9. Verify it

```bash
curl -sk "https://127.0.0.1:${LOCAL_PORT}/api/apps/app_templates/${TEMPLATE_ID}" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '{
      name,
      env_defaults: {
        SANDBOX_MAX_LIFETIME_HOURS: .env_defaults.SANDBOX_MAX_LIFETIME_HOURS,
        SUSPENDED_CONVERSATION_CLEANUP_DAYS: .env_defaults.SUSPENDED_CONVERSATION_CLEANUP_DAYS
      }
    }'
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

## 10. Stop the port-forward

```bash
kill "$PF_PID"
```
