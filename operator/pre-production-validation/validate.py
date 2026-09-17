import argparse
import os
import subprocess
from pathlib import Path

import jsonschema
import yaml


SCENARIO = Path(__file__).resolve().parent
ROOT = SCENARIO.parents[1]


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def validate_artifacts(matrix):
    artifacts = [
        ROOT / relative
        for item in matrix["checks"] + matrix["dependencies"]
        for relative in item.get("artifacts", [])
    ]
    missing = [path for path in artifacts if not path.is_file()]
    if missing:
        raise FileNotFoundError(missing[0])


def render_manifests():
    render_roots = [
        SCENARIO / "environments" / "envoy",
        SCENARIO / "environments" / "istio",
        SCENARIO / "fixtures",
    ]
    for render_root in render_roots:
        subprocess.run(
            ["kubectl", "kustomize", str(render_root)],
            check=True,
            capture_output=True,
        )


def validate_matrix():
    matrix = load(SCENARIO / "validation-matrix.yaml")
    if [check["order"] for check in matrix["checks"]] != list(range(1, 14)):
        raise ValueError("validation checks must be ordered from 1 through 13")
    validate_artifacts(matrix)
    render_manifests()


def validate_policies(operator_root):
    contract_root = operator_root / "specs" / "002-identity-transport-runtime" / "contracts"
    pairs = (
        ("auth-profile.schema.yaml", "auth-profile-fragment.yaml"),
        ("transport-security.schema.yaml", "transport-policy-fragment.yaml"),
    )
    for schema_name, document_name in pairs:
        schema = load(contract_root / schema_name)
        jsonschema.Draft202012Validator(schema).validate(
            load(SCENARIO / "policy" / document_name)
        )

    environment = os.environ.copy()
    environment["KAMIWAZA_EXAMPLES_ROOT"] = str(ROOT)
    subprocess.run(
        [
            "go",
            "test",
            "./internal/adminpolicy",
            "-run",
            "^TestReviewedPolicySatisfiesEveryCrossReferenceRule$",
            "-count=1",
        ],
        cwd=operator_root,
        env=environment,
        check=True,
    )


def validate_platform(operator_root):
    platform = load(ROOT / "operator" / "quickstart" / "kamiwaza-platform.yaml")
    crd_root = operator_root / "config" / "crd" / "bases"
    crds = [load(path) for path in crd_root.glob("*.yaml")]
    crd = next(
        (item for item in crds if item["spec"]["names"]["kind"] == platform["kind"]),
        None,
    )
    if crd is None:
        raise ValueError(f"no CRD found for {platform['kind']}")
    version = platform["apiVersion"].split("/", 1)[1]
    candidate = next(
        (item for item in crd["spec"]["versions"] if item["name"] == version),
        None,
    )
    if candidate is None:
        raise ValueError(f"no CRD schema found for {platform['apiVersion']}")
    jsonschema.Draft202012Validator(
        candidate["schema"]["openAPIV3Schema"]
    ).validate(platform)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--operator-root", type=Path, required=True)
    args = parser.parse_args()
    operator_root = args.operator_root.resolve()
    validate_matrix()
    validate_policies(operator_root)
    validate_platform(operator_root)
    print("Pre-production examples match platform operator contracts.")


if __name__ == "__main__":
    main()
