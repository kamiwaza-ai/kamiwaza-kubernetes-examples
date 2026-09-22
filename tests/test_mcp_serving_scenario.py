"""The MCP serving scenario has to describe the endpoints it actually declares.

A reader copies the endpoint out of the README and the manifests out of the
directory. If the two disagree, the copy that reaches a cluster serves nothing
at the address the reader was told to use, and the failure looks like a broken
platform rather than a wrong example.
"""

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCENARIO = ROOT / "protocols" / "mcp-serving"
README = SCENARIO / "README.md"
EXTENSION = SCENARIO / "extension-kamiwaza-mcp.yaml"
RAW_SERVER = SCENARIO / "raw-mcp-server.yaml"

# The path the server mounts the protocol at. Stated by the package, not by
# this repository, so a scenario that assumes another one is wrong here.
PROTOCOL_PATH = "/mcp"


def documents(path: Path) -> list[dict]:
    return [document for document in yaml.safe_load_all(path.read_text()) if document]


def only(objects: list[dict], kind: str) -> dict:
    matching = [object for object in objects if object["kind"] == kind]
    if len(matching) != 1:
        raise AssertionError(f"expected one {kind}, found {len(matching)}")
    return matching[0]


class ExtensionShapeTest(unittest.TestCase):
    def test_publishes_the_prefix_the_readme_tells_a_client_to_call(self):
        extension = only(documents(EXTENSION), "KamiwazaExtension")
        ingress = extension["spec"]["networking"]["ingress"]

        self.assertTrue(ingress["enabled"])
        self.assertIn(f"{ingress['pathPrefix']}{PROTOCOL_PATH}", README.read_text())

    def test_keeps_the_prefix_the_endpoint_is_addressed_with(self):
        """Stripping it would move the endpoint the README names."""
        extension = only(documents(EXTENSION), "KamiwazaExtension")

        self.assertFalse(extension["spec"]["networking"]["ingress"]["stripPrefix"])

    def test_probes_the_port_the_service_publishes(self):
        service = only(documents(EXTENSION), "KamiwazaExtension")["spec"]["services"][0]
        port = service["ports"][0]["containerPort"]

        self.assertEqual(service["healthCheck"]["httpGet"]["port"], port)


class RawServerShapeTest(unittest.TestCase):
    def test_rewrites_the_public_prefix_onto_the_servers_own_mount(self):
        """The workload knows nothing of the prefix the platform publishes."""
        route = only(documents(RAW_SERVER), "HTTPRoute")
        rule = route["spec"]["rules"][0]
        rewrite = rule["filters"][0]

        self.assertEqual(rewrite["type"], "URLRewrite")
        self.assertEqual(rewrite["urlRewrite"]["path"]["type"], "ReplacePrefixMatch")
        self.assertEqual(rewrite["urlRewrite"]["path"]["replacePrefixMatch"], "/")

    def test_routes_to_the_port_the_service_exposes(self):
        objects = documents(RAW_SERVER)
        service = only(objects, "Service")
        route = only(objects, "HTTPRoute")
        backend = route["spec"]["rules"][0]["backendRefs"][0]

        self.assertEqual(backend["name"], service["metadata"]["name"])
        self.assertEqual(backend["port"], service["spec"]["ports"][0]["port"])

    def test_attaches_to_the_gateway_in_the_platform_namespace(self):
        """The platform owns the Gateway; the scenario borrows a listener."""
        route = only(documents(RAW_SERVER), "HTTPRoute")
        parent = route["spec"]["parentRefs"][0]

        self.assertEqual(parent["kind"], "Gateway")
        self.assertEqual(parent["namespace"], "kamiwaza")


if __name__ == "__main__":
    unittest.main()
