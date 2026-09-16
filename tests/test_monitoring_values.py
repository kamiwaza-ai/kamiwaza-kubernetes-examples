import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
LOKI_VALUES = ROOT / "monitoring" / "grafana-prometheus" / "loki-values.yaml"


class LokiValuesTest(unittest.TestCase):
    def test_disables_canary_at_chart_contract_path(self):
        values = yaml.safe_load(LOKI_VALUES.read_text())

        self.assertIs(values["lokiCanary"]["enabled"], False)


if __name__ == "__main__":
    unittest.main()
