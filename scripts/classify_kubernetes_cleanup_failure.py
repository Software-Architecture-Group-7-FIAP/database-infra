#!/usr/bin/env python3
"""Allow teardown to continue only when kubectl failed on an unreachable API endpoint."""

from __future__ import annotations

import re
import sys
from pathlib import Path


NETWORK_FAILURE_PATTERNS = (
    re.compile(r"\bdial tcp\b.*\bi/o timeout\b", re.IGNORECASE),
    re.compile(r"\bconnect: connection timed out\b", re.IGNORECASE),
    re.compile(r"\bconnect: network is unreachable\b", re.IGNORECASE),
    re.compile(r"\bno route to host\b", re.IGNORECASE),
    re.compile(r"\bTLS handshake timeout\b", re.IGNORECASE),
    re.compile(r"\bcontext deadline exceeded\b", re.IGNORECASE),
    re.compile(
        r"\bClient\.Timeout exceeded while awaiting headers\b", re.IGNORECASE
    ),
)

SERVER_FAILURE_PATTERNS = (
    re.compile(r"\bForbidden\b", re.IGNORECASE),
    re.compile(r"\bUnauthorized\b", re.IGNORECASE),
    re.compile(r"\bError from server\b", re.IGNORECASE),
    re.compile(r"\bno credentials\b", re.IGNORECASE),
)


def is_network_unreachable(error_output: str) -> bool:
    """Return true only for transport timeouts that can be deferred to EKS teardown."""
    if not error_output.strip():
        return False

    if any(pattern.search(error_output) for pattern in SERVER_FAILURE_PATTERNS):
        return False

    return any(pattern.search(error_output) for pattern in NETWORK_FAILURE_PATTERNS)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print("Expected one private kubectl diagnostic path.", file=sys.stderr)
        return 2

    try:
        error_output = Path(arguments[0]).read_text(encoding="utf-8", errors="replace")
    except OSError:
        print("Kubernetes cleanup diagnostics could not be read; teardown is blocked.")
        return 1

    if is_network_unreachable(error_output):
        print(
            "The Kubernetes API endpoint was unreachable from the runner; "
            "bootstrap object cleanup is deferred to EKS cluster teardown."
        )
        return 0

    print(
        "Kubernetes cleanup failed for a non-network reason; Terraform destroy remains blocked."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
