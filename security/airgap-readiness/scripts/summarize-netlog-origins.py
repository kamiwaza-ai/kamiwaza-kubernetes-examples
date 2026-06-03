#!/usr/bin/env python3
"""Summarize external origins in a Chrome NetLog (``--log-net-log``) capture.

Unlike a DevTools HAR export, a NetLog records the whole browser session across
all tabs, navigations, and refreshes, and includes requests that failed or were
blocked (for example by the air-gap dead proxy). This makes it the better source
for "which external origins did the browser try to reach during the session".
"""

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
    parser.add_argument("--netlog", required=True, type=Path, help="Path to a Chrome NetLog capture.")
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


def load_netlog(path: Path) -> dict:
    """Load a NetLog, tolerating the truncation left by a hard browser exit.

    A cleanly closed NetLog is valid JSON. If Chrome was killed instead of quit,
    the ``events`` array is left unterminated. In that case, decode the
    ``constants`` block and then walk the ``events`` array one element at a time,
    keeping every complete event and stopping at the first incomplete one.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    decoder = json.JSONDecoder()

    def value_after(key: str) -> int:
        marker = f'"{key}":'
        idx = text.find(marker)
        if idx == -1:
            return -1
        idx += len(marker)
        while idx < len(text) and text[idx] in " \t\r\n":
            idx += 1
        return idx

    constants_at = value_after("constants")
    constants = {}
    if constants_at != -1:
        try:
            constants, _ = decoder.raw_decode(text, constants_at)
        except json.JSONDecodeError:
            constants = {}

    events: list = []
    arr_at = value_after("events")
    if arr_at != -1 and arr_at < len(text) and text[arr_at] == "[":
        pos = arr_at + 1
        while pos < len(text):
            while pos < len(text) and text[pos] in " \t\r\n,":
                pos += 1
            if pos >= len(text) or text[pos] == "]":
                break
            try:
                event, end = decoder.raw_decode(text, pos)
            except json.JSONDecodeError:
                break  # truncated final event; keep everything decoded so far
            events.append(event)
            pos = end

    if not events and constants_at == -1:
        raise SystemExit("could not parse this file as a NetLog; is it a NetLog capture?")
    return {"constants": constants, "events": events}


def main() -> int:
    args = parse_args()

    allowed_hosts = {normalize_host(host) for host in args.allow_host if host.strip()}
    allowed_origins = {origin.lower().rstrip("/") for origin in args.allow_origin}

    netlog = load_netlog(args.netlog)
    constants = netlog.get("constants", {})

    # NetLog events reference type / source-type / net-error by integer id; the
    # decode tables live in "constants". Invert the name->id maps we need.
    source_types = constants.get("logSourceType", {})
    url_request_type = source_types.get("URL_REQUEST")
    event_types = constants.get("logEventTypes", {})
    start_job_type = event_types.get("URL_REQUEST_START_JOB")
    net_errors = {code: name for name, code in constants.get("netError", {}).items()}

    @dataclass
    class Req:
        url: str = ""
        method: str = ""
        net_error: int | None = None

    requests: dict[int, Req] = defaultdict(Req)

    for event in netlog.get("events", []):
        source = event.get("source") or {}
        if url_request_type is not None and source.get("type") != url_request_type:
            continue
        sid = source.get("id")
        if sid is None:
            continue
        params = event.get("params") or {}
        req = requests[sid]
        if not req.url and isinstance(params.get("url"), str):
            req.url = params["url"]
        if not req.method and isinstance(params.get("method"), str):
            req.method = params["method"]
        if "net_error" in params:
            req.net_error = params.get("net_error")

    def status_label(req: Req) -> str:
        if req.net_error in (None, 0):
            return "ok"
        name = net_errors.get(req.net_error)
        return name or f"net_error:{req.net_error}"

    allowed: dict[str, OriginSummary] = defaultdict(OriginSummary)
    external: dict[str, OriginSummary] = defaultdict(OriginSummary)

    for req in requests.values():
        if not req.url:
            continue
        parsed = urlparse(req.url)
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
        summary.methods[req.method or "?"] += 1
        summary.statuses[status_label(req)] += 1
        if len(summary.examples) < 3:
            summary.examples.append(req.url)

    print(f"NetLog: {args.netlog}")
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
    print("PASS: no external origins observed in this NetLog.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
