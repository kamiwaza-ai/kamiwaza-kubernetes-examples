import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("render-platform-images.py")
MODULE_SPEC = importlib.util.spec_from_file_location("render_platform_images", SCRIPT)
RENDERER = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(RENDERER)


class RenderPlatformImagesTest(unittest.TestCase):
    def setUp(self):
        self.metadata = {
            "schemaVersion": "platform.kamiwaza.io/release-metadata-v3",
            "platformVersion": "1.3.0",
            "reviewedImages": [
                {
                    "capability": "durableData",
                    "role": "database",
                    "reference": "ghcr.io/example/images/database@sha256:" + "a" * 64,
                },
                {
                    "capability": "durableData",
                    "role": "coordination",
                    "reference": "ghcr.io/example/images/coordination@sha256:" + "b" * 64,
                },
                {
                    "capability": "metadataCatalog",
                    "role": "application",
                    "reference": "ghcr.io/example/images/catalog@sha256:" + "c" * 64,
                },
            ],
        }

    def test_renders_only_selected_release_pins(self):
        patch = RENDERER.render(self.metadata, ["durableData"])
        self.assertEqual(patch["spec"]["version"], "1.3.0")
        self.assertEqual(
            [(pin["capability"], pin["role"]) for pin in patch["spec"]["images"]["pinned"]],
            [("durableData", "database"), ("durableData", "coordination")],
        )

    def test_refuses_unreviewable_inventory(self):
        tagged = json.loads(json.dumps(self.metadata))
        tagged["reviewedImages"][0]["reference"] = "ghcr.io/example/database:latest"
        placeholder = json.loads(json.dumps(self.metadata))
        placeholder["reviewedImages"][0]["reference"] = (
            "ghcr.io/example/images/database@sha256:" + "0" * 64
        )
        duplicate = json.loads(json.dumps(self.metadata))
        duplicate["reviewedImages"].append(dict(duplicate["reviewedImages"][0]))
        malformed = json.loads(json.dumps(self.metadata))
        malformed["reviewedImages"].append("not-an-image")
        cases = [
            ("unknown capability", self.metadata, ["missing"]),
            ("operator infrastructure", self.metadata, ["platformTransport"]),
            ("mutable tag", tagged, ["durableData"]),
            ("placeholder digest", placeholder, ["durableData"]),
            ("duplicate role", duplicate, ["durableData"]),
            ("malformed image", malformed, ["durableData"]),
        ]
        for name, metadata, selection in cases:
            with self.subTest(name=name), self.assertRaises(ValueError):
                RENDERER.render(metadata, selection)

    def test_cli_patch_applies_to_quickstart(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            metadata_path = directory / "compatibility.json"
            patch_path = directory / "images.patch.json"
            metadata_path.write_text(json.dumps(self.metadata), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(metadata_path), "--capability", "durableData"],
                check=True,
                capture_output=True,
                text=True,
            )
            patch_path.write_text(result.stdout, encoding="utf-8")
            quickstart = SCRIPT.parent.parent / "quickstart" / "kamiwaza-platform.yaml"
            rendered = subprocess.run(
                [
                    "kubectl",
                    "patch",
                    "--local",
                    "--type=merge",
                    "--filename",
                    str(quickstart),
                    "--patch-file",
                    str(patch_path),
                    "--output=json",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            platform = json.loads(rendered.stdout)
            self.assertEqual(platform["spec"]["images"], json.loads(result.stdout)["spec"]["images"])



if __name__ == "__main__":
    unittest.main()
