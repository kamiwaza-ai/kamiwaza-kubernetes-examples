"""This repository publishes the 1.3.0 operator lifecycle and nothing older.

A scenario that reaches for the retired lifecycle reads as current guidance,
which is worse than no scenario: a reader follows it, and either the command
does not exist or it edits state the operator immediately reverts. Each marker
below names a surface that is gone in 1.3.0, so its reappearance in a tracked
file is the regression this guard exists to catch.
"""

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# marker -> why it is gone. Case-sensitive where the lowercase spelling is a
# real word in current guidance.
RETIRED_SURFACES = {
    "helmfile": "the Helmfile lifecycle is replaced by the platform operator",
    "Helmfile": "the Helmfile lifecycle is replaced by the platform operator",
    "cluster/values/overrides": "chart values overrides are not platform intent",
    "KAMIWAZA_K8S_RUNTIME": "runtime selection belonged to the retired installer",
    "install-lite": "the lite/full environment profiles were Helmfile environments",
    "traefik": "routing is expressed as Gateway API objects, vendor-neutrally",
    "Traefik": "routing is expressed as Gateway API objects, vendor-neutrally",
    "IngressRoute": "routing is expressed as Gateway API objects, vendor-neutrally",
    "ray_serve": "Ray Serve is no longer the request surface, so its metrics do not exist",
    "RayService": "no Ray CRD is installed",
    "kuberay-operator": "KubeRay is not part of the platform",
    "neo4j": "Neo4j is not part of the platform",
    "Neo4j": "Neo4j is not part of the platform",
}

# Exact tracked paths allowed to name a marker, with the reason. A migration
# note has to be able to say what it replaced.
ALLOWED = {
    ("Traefik", "tests/test_diagnostic_commands.py"): "asserts the vendor is absent from output",
    ("IngressRoute", "security/cac/README.md"): "migration note naming the shape it replaced",
    ("traefik", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("Traefik", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("IngressRoute", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("helmfile", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("Helmfile", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("cluster/values/overrides", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("KAMIWAZA_K8S_RUNTIME", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("install-lite", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("ray_serve", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("RayService", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("kuberay-operator", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("neo4j", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
    ("Neo4j", "tests/test_no_legacy_surfaces.py"): "this guard declares the markers",
}


def tracked_files_naming(marker: str) -> list[str]:
    """Tracked paths containing *marker*, read from git rather than a walk.

    git is the authority on what this repository publishes: a walk would also
    report ignored local material such as `local-secrets/` and `out/`.
    """
    completed = subprocess.run(
        ["git", "grep", "--files-with-matches", "-I", "--fixed-strings", "--", marker],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode not in (0, 1):
        raise RuntimeError(completed.stderr.strip())
    return sorted(path for path in completed.stdout.splitlines() if path)


class RetiredLifecycleTest(unittest.TestCase):
    def test_no_scenario_names_a_retired_surface(self):
        violations = []
        for marker, reason in RETIRED_SURFACES.items():
            for path in tracked_files_naming(marker):
                if (marker, path) in ALLOWED:
                    continue
                violations.append(f"{path}: {marker!r} — {reason}")

        self.assertEqual(violations, [], "\n".join(["retired surfaces found:", *violations]))


if __name__ == "__main__":
    unittest.main()
