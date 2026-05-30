"""Botocore region hotfix for custom / non-default AWS regions and partitions.

botocore only knows the regions baked into its bundled endpoints data, so a custom
or non-default partition region is absent from that list and a Bedrock call against
it is rejected before it ever leaves the pod. The Kamiwaza frontend also rejects
non-amazonaws.com endpoint URLs, but the *backend* does not — so extending the
region list is enough to drive a custom Bedrock endpoint from the backend.

This file is auto-imported by CPython at interpreter startup when its directory is
on PYTHONPATH (the `sitecustomize` hook). Mount it at /app/hotfix and prepend that
dir to PYTHONPATH (see values-snippet.yaml) — no application code changes.

Regions come from the KAMIWAZA_EXTRA_BEDROCK_REGIONS env var (comma-separated) so
operators never edit this file:

    KAMIWAZA_EXTRA_BEDROCK_REGIONS=your-region-1,your-region-2

NOTE: this does NOT disable TLS verification. Trust the endpoint's CA properly via
the parent CA-trust recipe (../trust-bundle-values-snippet.yaml) and keep
verification ON. Do not add SSL_VERIFY=False here.
"""

import os

import botocore.session

# Comma-separated exact region names. Falls back to a hardcoded set if unset.
_env = os.environ.get("KAMIWAZA_EXTRA_BEDROCK_REGIONS", "")
REGIONS = {r.strip() for r in _env.split(",") if r.strip()} or {
    # Edit here only if you cannot set the env var. Use EXACT region codes.
    # "your-region-1",
}

# Services whose region lists should be extended (Bedrock is split across two).
_SERVICES = {"bedrock", "bedrock-runtime"}

_orig = botocore.session.Session.get_available_regions


def _patched(self, service_name, partition_name="aws", allow_non_regional=False):
    out = list(_orig(self, service_name, partition_name, allow_non_regional))
    if service_name in _SERVICES:
        for region in REGIONS:
            if region not in out:
                out.append(region)
    return out


botocore.session.Session.get_available_regions = _patched
