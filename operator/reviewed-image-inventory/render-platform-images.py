#!/usr/bin/env python3
"""Render a KamiwazaPlatform image patch from signed release metadata."""

import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA_VERSION = "platform.kamiwaza.io/release-metadata-v3"
DIGEST_REFERENCE = re.compile(
    r"^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?"
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+"
    r"@sha256:[0-9a-f]{64}$"
)
ZERO_DIGEST = "sha256:" + "0" * 64


def arguments():
    parser = argparse.ArgumentParser(
        description="Render a JSON Merge Patch for spec.images.pinned."
    )
    parser.add_argument("release_metadata", type=Path)
    parser.add_argument(
        "--capability",
        action="append",
        required=True,
        help="Capability to include; repeat for each enabled capability.",
    )
    return parser.parse_args()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def release_inventory(metadata):
    require(isinstance(metadata, dict), "release metadata root must be an object")
    require(
        metadata.get("schemaVersion") == SCHEMA_VERSION,
        f"release metadata must use {SCHEMA_VERSION}",
    )
    platform_version = metadata.get("platformVersion")
    require(isinstance(platform_version, str), "release metadata must name platformVersion")
    require(bool(platform_version), "release metadata must name platformVersion")
    images = metadata.get("reviewedImages")
    require(isinstance(images, list), "release metadata must contain reviewedImages")
    return platform_version, images


def selected_capabilities(images, requested):
    selected = set(requested)
    require(
        "platformTransport" not in selected,
        "platformTransport belongs to the installed operator release, "
        "not platform image intent",
    )
    available = {
        image.get("capability")
        for image in images
        if isinstance(image, dict) and isinstance(image.get("capability"), str)
    }
    unknown = sorted(selected - available)
    require(not unknown, "unknown capability selection: " + ", ".join(unknown))
    return selected


def checked_reference(capability, role, reference):
    message = f"{capability}/{role} must use one canonical SHA-256 digest"
    require(isinstance(reference, str), message)
    require(bool(DIGEST_REFERENCE.fullmatch(reference)), message)
    require(
        not reference.endswith(ZERO_DIGEST),
        f"{capability}/{role} carries the release placeholder digest",
    )
    return reference


def reviewed_pin(image, selected, seen):
    if not isinstance(image, dict):
        return None
    capability = image.get("capability")
    if capability not in selected:
        return None
    role = image.get("role")
    require(isinstance(role, str), f"{capability} image must name a role")
    require(bool(role), f"{capability} image must name a role")
    key = (capability, role)
    require(key not in seen, f"duplicate reviewed image: {capability}/{role}")
    seen.add(key)
    return {
        "capability": capability,
        "role": role,
        "reference": checked_reference(capability, role, image.get("reference")),
    }


def render(metadata, requested):
    platform_version, images = release_inventory(metadata)
    selected = selected_capabilities(images, requested)
    seen = set()
    pins = []
    for image in images:
        pin = reviewed_pin(image, selected, seen)
        if pin is not None:
            pins.append(pin)
    return {"spec": {"version": platform_version, "images": {"pinned": pins}}}


def main():
    options = arguments()
    try:
        metadata = json.loads(options.release_metadata.read_text(encoding="utf-8"))
        patch = render(metadata, options.capability)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    json.dump(patch, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
