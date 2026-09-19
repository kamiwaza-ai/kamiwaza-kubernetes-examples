import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "troubleshooting" / "diagnostic-commands" / "kamiwaza-diagnostics.sh"


class DiagnosticCommandsTest(unittest.TestCase):
    def test_reports_operator_managed_platform(self):
        fake_kubectl = """#!/usr/bin/env bash
case "$*" in
  "get kamiwazaplatform -A"*)
    printf 'kamiwaza-examples\\tkamiwaza\\t4\\t4\\tTrue\\tAllComponentsReady\\n'
    ;;
  *"status.components"*)
    printf 'applicationAPI\\trequest surface is ready\\nwebInterface\\tfrontend is ready\\n'
    ;;
  "get pods -n kamiwaza-examples --no-headers"*)
    printf 'core-api-1 1/1 Running 0 1m\\nfrontend-1 1/1 Running 0 1m\\n'
    ;;
  "get pvc -n kamiwaza-examples --no-headers"*)
    printf 'data-core-postgres-0 Bound pvc-1 1Gi RWO local-path 1m\n'
    ;;
  "get modeldeployments -n kamiwaza-examples"*)
    printf 'model-a 2 2 True KubernetesWorkloadReady\n'
    ;;
  "get kamiwazaextensions -n kamiwaza-examples"*)
    printf 'extension-a Running True\\n'
    ;;
  "get events -n kamiwaza-examples"*)
    ;;
  *)
    printf 'unexpected kubectl call: %s\\n' "$*" >&2
    exit 1
    ;;
esac
"""
        with tempfile.TemporaryDirectory() as directory:
            kubectl = Path(directory) / "kubectl"
            kubectl.write_text(fake_kubectl)
            kubectl.chmod(kubectl.stat().st_mode | stat.S_IXUSR)
            environment = os.environ | {"PATH": f"{directory}:{os.environ['PATH']}"}
            result = subprocess.run(
                [SCRIPT],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Platform: kamiwaza-examples/kamiwaza", result.stdout)
        self.assertIn("Platform Ready: AllComponentsReady", result.stdout)
        self.assertIn("All 2 pods ready", result.stdout)
        self.assertNotIn("Core scheduler", result.stdout)
        self.assertNotIn("Traefik", result.stdout)


if __name__ == "__main__":
    unittest.main()
