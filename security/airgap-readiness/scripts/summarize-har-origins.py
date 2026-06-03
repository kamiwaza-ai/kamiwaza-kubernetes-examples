#!/usr/bin/env python3
"""Summarize external origins in a Chrome DevTools HAR export."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse


IGNORED_SCHEMES = {"", "about", "blob", "chrome", "chrome-extension", "data", "devtools"}


@dataclass
class OriginSummary:
    count: int = 0
    methods: Counter[str] = field(default_factory=Counter)
    statuses: Counter[str] = field(default_factory=Counter)
    examples: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--har", required=True, type=Path, help="Path to Chrome DevTools HAR export.")
    parser.add_argument(
        "--allow-host",
        action="append",
        default=[],
        help="Allowed hostname. Exact host and subdomains are allowed.",
    )
    parser.add_argument(
        "--allow-origin",
        action="append",
        default=[],
        help="Allowed origin, for example https://example.test.",
    )
    parser.add_argument(
        "--warn-only",
        action="store_true",
        help="Exit 0 even when external origins are found.",
    )
    return parser.parse_args()


def normalize_host(value: str) -> str:
    value = value.strip().lower()
    if "://" in value:
        value = urlparse(value).hostname or value
    return value.strip(".")


def host_allowed(host: str, allowed_hosts: set[str]) -> bool:
    host = host.lower().strip(".")
    for allowed in allowed_hosts:
        if host == allowed or host.endswith(f".{allowed}"):
            return True
    return False


def origin_allowed(origin: str, allowed_origins: set[str]) -> bool:
    return origin.lower().rstrip("/") in allowed_origins


def status_label(entry: dict) -> str:
    response = entry.get("response") or {}
    status = response.get("status")
    if status:
        return str(status)
    error = entry.get("_error") or response.get("_error")
    if error:
        return f"error:{error}"
    return "0/blocked"


def header_value(headers: list[dict], name: str) -> str:
    name = name.lower()
    for header in headers or []:
        if (header.get("name") or "").lower() == name:
            return header.get("value") or ""
    return ""


def request_source(entry: dict, request: dict, pages: dict[str, str]) -> str:
    """Describe where a request came from, to make external origins debuggable.

    Chrome DevTools HARs record an ``_initiator`` (the script or parser that
    triggered the request); fall back to the ``Referer`` header, then to the
    page the entry belongs to.
    """
    initiator = entry.get("_initiator") or {}
    itype = initiator.get("type")

    stack = initiator.get("stack") or {}
    frames = stack.get("callFrames") or []
    if frames:
        frame = frames[0]
        location = frame.get("url") or "?"
        line = frame.get("lineNumber")
        if isinstance(line, int):
            # DevTools line numbers are 0-based; show 1-based for readability.
            location = f"{location}:{line + 1}"
            column = frame.get("columnNumber")
            if isinstance(column, int):
                location = f"{location}:{column + 1}"
        return f"script {location}"

    if initiator.get("url"):
        location = initiator["url"]
        line = initiator.get("lineNumber")
        if isinstance(line, int):
            location = f"{location}:{line + 1}"
        return f"{itype or 'initiator'} {location}"

    referer = header_value(request.get("headers"), "referer")
    if referer:
        return f"referer {referer}"

    pageref = entry.get("pageref")
    if pageref and pageref in pages:
        return f"page {pages[pageref]}"

    if itype:
        return itype

    return "unknown"


def main() -> int:
    args = parse_args()

    allowed_hosts = {normalize_host(host) for host in args.allow_host if host.strip()}
    allowed_origins = {origin.lower().rstrip("/") for origin in args.allow_origin}

    with args.har.open("r", encoding="utf-8") as f:
        har = json.load(f)

    log = har.get("log", {})
    entries = log.get("entries", [])
    pages = {
        page.get("id"): (page.get("title") or page.get("id") or "")
        for page in log.get("pages", [])
        if page.get("id")
    }
    allowed: dict[str, OriginSummary] = defaultdict(OriginSummary)
    external: dict[str, OriginSummary] = defaultdict(OriginSummary)

    for entry in entries:
        request = entry.get("request") or {}
        url = request.get("url") or ""
        parsed = urlparse(url)
        if parsed.scheme.lower() in IGNORED_SCHEMES:
            continue
        host = (parsed.hostname or "").lower()
        if not host:
            continue
        origin = f"{parsed.scheme}://{host}"
        if parsed.port:
            origin = f"{origin}:{parsed.port}"

        bucket = allowed if (
            host_allowed(host, allowed_hosts) or origin_allowed(origin, allowed_origins)
        ) else external

        summary = bucket[origin]
        summary.count += 1
        summary.methods[request.get("method") or "?"] += 1
        summary.statuses[status_label(entry)] += 1
        if len(summary.examples) < 3:
            summary.examples.append(f"{url}  <- {request_source(entry, request, pages)}")

    print(f"HAR: {args.har}")
    print(f"Allowed hosts: {', '.join(sorted(allowed_hosts)) or '(none)'}")
    print(f"Allowed origins: {', '.join(sorted(allowed_origins)) or '(none)'}")
    print()

    print(f"Allowed origins seen: {len(allowed)}")
    for origin, summary in sorted(allowed.items()):
        statuses = ", ".join(f"{key}={value}" for key, value in sorted(summary.statuses.items()))
        print(f"  {origin} requests={summary.count} statuses=[{statuses}]")

    print()
    print(f"External origins seen: {len(external)}")
    for origin, summary in sorted(external.items()):
        methods = ", ".join(f"{key}={value}" for key, value in sorted(summary.methods.items()))
        statuses = ", ".join(f"{key}={value}" for key, value in sorted(summary.statuses.items()))
        print(f"  {origin}")
        print(f"    requests={summary.count} methods=[{methods}] statuses=[{statuses}]")
        for example in summary.examples:
            print(f"    example={example}")

    if external:
        print()
        print("FAIL: external origins were observed. Classify each as blocking, eliminated, or non-blocking noise.")
        return 0 if args.warn_only else 1

    print()
    print("PASS: no external origins observed in this HAR.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
