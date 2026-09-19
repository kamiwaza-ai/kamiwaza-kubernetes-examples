#!/usr/bin/env python3
"""Serve the Kamiwaza MCP over standard input and output for one member.

Shape C of this scenario. An MCP host launches this command; the pipe carries no
per-request credential, so the member is established once from the credential the
process starts with and every call runs as that member.

The library ships no command for this on purpose: a process that serves one
member has to be told which member, and the three facts below (credential,
member, tenant) are what the platform provisioned together.

    KAMIWAZA_API_URL=https://kamiwaza.example.com/api \
    KAMIWAZA_API_KEY=<personal access token> \
    KAMIWAZA_MEMBER=kev KAMIWAZA_TENANT=acme \
    python stdio-launcher.py
"""

from __future__ import annotations

import asyncio
import os
import sys

from kamiwaza_mcp.transport.stdio import (
    ProvisionedCaller,
    local_deployment,
    serve_stdio,
)


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(
            f"{name} is not set. A local process serves one member under one "
            "credential, and neither can be guessed."
        )
    return value


def main() -> None:
    caller = ProvisionedCaller(
        credential=_required("KAMIWAZA_API_KEY"),
        member=_required("KAMIWAZA_MEMBER"),
        tenant=_required("KAMIWAZA_TENANT"),
    )
    asyncio.run(
        serve_stdio(
            local_deployment(
                caller,
                platform_base_url=_required("KAMIWAZA_API_URL"),
            )
        )
    )


if __name__ == "__main__":
    main()
