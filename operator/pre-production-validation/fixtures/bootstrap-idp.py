import http.client
import json
import os
import ssl
import time
import urllib.parse


IDP_HOST = "external-idp.platform-validation-dependencies.svc.cluster.local"
REALM = "enterprise"


def request(path, *, data=None, method="GET", token=None):
    content_type = (
        "application/x-www-form-urlencoded"
        if isinstance(data, bytes)
        else "application/json"
    )
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if isinstance(data, dict) else data
    with http.client.HTTPConnection(IDP_HOST, 8080, timeout=10) as connection:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        payload = response.read()
    if response.status >= 400:
        raise RuntimeError(f"identity provider returned HTTP {response.status}")
    return json.loads(payload) if payload else None


def wait_for_idp():
    for _attempt in range(120):
        try:
            request("/realms/master")
            return
        except (OSError, RuntimeError):
            time.sleep(2)
    raise RuntimeError("external identity provider did not become ready")


def find_one(path, field, value, token):
    query = urllib.parse.urlencode({field: value})
    matches = [
        item
        for item in request(f"{path}?{query}", token=token)
        if item.get(field) == value
    ]
    if len(matches) != 1:
        raise RuntimeError(f"expected one {field}={value}, found {len(matches)}")
    return matches[0]


def publish_metadata(name, key, metadata):
    namespace = os.environ["POD_NAMESPACE"]
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]
    token = open(
        "/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8"
    ).read()
    context = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    )
    path = f"/api/v1/namespaces/{namespace}/configmaps/{name}"
    with http.client.HTTPSConnection(
        host,
        int(port),
        context=context,
        timeout=10,
    ) as connection:
        connection.request(
            "PATCH",
            path,
            body=json.dumps({"data": {key: metadata}}).encode(),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/merge-patch+json",
            },
        )
        response = connection.getresponse()
        response.read()
    if response.status >= 400:
        raise RuntimeError(f"Kubernetes API returned HTTP {response.status}")


wait_for_idp()
credentials = urllib.parse.urlencode(
    {
        "grant_type": "password",
        "client_id": "admin-cli",
        "username": "admin",
        "password": os.environ["IDP_ADMIN_PASSWORD"],
    }
).encode()
token = request(
    "/realms/master/protocol/openid-connect/token",
    data=credentials,
    method="POST",
)["access_token"]
client = find_one(f"/admin/realms/{REALM}/clients", "clientId", "kamiwaza-broker", token)
client["secret"] = os.environ["OIDC_CLIENT_SECRET"]
request(f"/admin/realms/{REALM}/clients/{client['id']}", data=client, method="PUT", token=token)
user = find_one(f"/admin/realms/{REALM}/users", "username", "lab-user", token)
request(
    f"/admin/realms/{REALM}/users/{user['id']}/reset-password",
    data={"type": "password", "value": os.environ["LAB_USER_PASSWORD"], "temporary": False},
    method="PUT",
    token=token,
)
discovery = request(f"/realms/{REALM}/.well-known/openid-configuration")
publish_metadata(
    "enterprise-oidc-metadata",
    "metadata.json",
    json.dumps(discovery, separators=(",", ":")),
)
with http.client.HTTPConnection(IDP_HOST, 8080, timeout=10) as connection:
    connection.request("GET", f"/realms/{REALM}/protocol/saml/descriptor")
    response = connection.getresponse()
    metadata = response.read().decode()
if response.status >= 400:
    raise RuntimeError(f"identity provider returned HTTP {response.status}")
publish_metadata("enterprise-saml-metadata", "metadata.xml", metadata)
