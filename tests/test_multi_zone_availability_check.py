import builtins
import io
import json
import ssl
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHECKS = ROOT / "scheduling" / "multi-zone" / "availability-checks.yaml"


class Response(io.BytesIO):
    def __init__(self, payload):
        super().__init__(json.dumps(payload).encode())


def zone_placement_script():
    for document in yaml.safe_load_all(CHECKS.read_text()):
        if document.get("kind") != "Job":
            continue
        if document["metadata"]["name"] == "zone-placement-check":
            return document["spec"]["template"]["spec"]["containers"][0]["args"][0]
    raise AssertionError("zone-placement-check Job not found")


def fake_urlopen(request, **_kwargs):
    url = request.full_url
    if url.endswith("/deployments/core-raycluster-worker"):
        return Response(
            {
                "metadata": {"generation": 1},
                "spec": {"selector": {"matchLabels": {"app": "worker"}}},
                "status": {"observedGeneration": 1, "readyReplicas": 3},
            }
        )
    if "/pods?labelSelector=" in url:
        return Response(
            {
                "items": [
                    {
                        "metadata": {"name": f"worker-{index}"},
                        "spec": {"nodeName": f"node-{index}"},
                        "status": {
                            "conditions": [{"type": "Ready", "status": "True"}]
                        },
                    }
                    for index in range(3)
                ]
            }
        )
    if "/api/v1/nodes/node-" in url:
        return Response(
            {"metadata": {"labels": {"topology.kubernetes.io/zone": "zone-a"}}}
        )
    raise AssertionError(f"unexpected Kubernetes API request: {url}")


class ZonePlacementCheckTest(unittest.TestCase):
    def test_rejects_distinct_nodes_in_one_zone(self):
        script = zone_placement_script()
        token = mock.mock_open(read_data="token")
        with (
            mock.patch.dict(
                "os.environ",
                {
                    "KUBERNETES_SERVICE_HOST": "kubernetes.default.svc",
                    "KUBERNETES_SERVICE_PORT_HTTPS": "443",
                },
            ),
            mock.patch.object(builtins, "open", token),
            mock.patch.object(ssl, "create_default_context", return_value=object()),
            mock.patch.object(urllib.request, "urlopen", side_effect=fake_urlopen),
            self.assertRaises(AssertionError),
        ):
            exec(script, {})


if __name__ == "__main__":
    unittest.main()
