import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCENARIO = ROOT / "operator" / "pre-production-validation"
MATRIX = SCENARIO / "validation-matrix.yaml"
EXPECTED_DEPENDENCIES = {
    "gateway-implementations",
    "controller-free-cluster",
    "external-identity-providers",
    "cac-piv-edge",
    "enforcing-egress-proxy",
    "mutual-tls-destination",
    "resumable-stream",
}
EXPECTED_DEPLOYMENTS = {
    "external-idp",
    "external-directory",
    "cac-piv-edge",
    "egress-proxy",
    "mutual-tls-destination",
    "resumable-stream",
}


def load_documents(text):
    return [document for document in yaml.safe_load_all(text) if document]


class PreProductionValidationTest(unittest.TestCase):
    def test_matrix_covers_every_workflow_and_dependency(self):
        matrix = yaml.safe_load(MATRIX.read_text(encoding="utf-8"))
        self.assertEqual(
            matrix["schemaVersion"],
            "examples.kamiwaza.ai/pre-production-validation-v1",
        )
        self.assertEqual(
            [check["order"] for check in matrix["checks"]], list(range(1, 14))
        )
        self.assertEqual(
            {dependency["id"] for dependency in matrix["dependencies"]},
            EXPECTED_DEPENDENCIES,
        )
        for dependency in matrix["dependencies"]:
            for field in ("setup", "verify"):
                path = ROOT / dependency[field]
                self.assertTrue(path.is_file(), f"missing {field}: {path}")
            for artifact in dependency["artifacts"]:
                path = ROOT / artifact
                self.assertTrue(path.is_file(), f"missing artifact: {path}")

    def test_dependency_stack_is_runnable_and_contains_no_secret_values(self):
        rendered = subprocess.run(
            ["kubectl", "kustomize", str(SCENARIO / "fixtures")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        documents = load_documents(rendered)
        deployments = {
            document["metadata"]["name"]
            for document in documents
            if document.get("kind") == "Deployment"
        }
        self.assertEqual(deployments, EXPECTED_DEPLOYMENTS)
        self.assertFalse(any(document.get("kind") == "Secret" for document in documents))
        for document in documents:
            if document.get("kind") != "Deployment":
                continue
            for container in document["spec"]["template"]["spec"]["containers"]:
                self.assertRegex(container["image"], r"@sha256:[a-f0-9]{64}$")

    def test_gateway_environments_use_distinct_implementations(self):
        classes = set()
        for environment in ("envoy", "istio"):
            rendered = subprocess.run(
                ["kubectl", "kustomize", str(SCENARIO / "environments" / environment)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            gateways = [
                document
                for document in load_documents(rendered)
                if document.get("kind") == "Gateway"
            ]
            self.assertEqual(len(gateways), 1)
            classes.add(gateways[0]["spec"]["gatewayClassName"])
        self.assertEqual(len(classes), 2)


if __name__ == "__main__":
    unittest.main()
