#!/usr/bin/env python3
"""Report a sanitized Kubernetes cleanup failure without allowing database teardown."""

from __future__ import annotations

import re
import sys
from pathlib import Path


NETWORK_CONNECT_PATTERNS = (
    re.compile(r"\bdial tcp\b.*\bi/o timeout\b", re.IGNORECASE),
    re.compile(r"\bconnect: connection timed out\b", re.IGNORECASE),
    re.compile(r"\bconnect: network is unreachable\b", re.IGNORECASE),
    re.compile(r"\bno route to host\b", re.IGNORECASE),
)

REQUEST_TIMEOUT_PATTERNS = (
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


def classify_failure(error_output: str) -> str:
    """Return a fixed diagnostic category; no category permits teardown to continue."""
    if not error_output.strip():
        return "diagnostics_unavailable"

    if any(pattern.search(error_output) for pattern in SERVER_FAILURE_PATTERNS):
        return "api_rejected_request"

    if any(pattern.search(error_output) for pattern in NETWORK_CONNECT_PATTERNS):
        return "network_connection_failed"

    if any(pattern.search(error_output) for pattern in REQUEST_TIMEOUT_PATTERNS):
        return "request_timed_out"

    return "unclassified_failure"


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

    category = classify_failure(error_output)
    print(f"Kubernetes cleanup failed ({category}); Terraform destroy remains blocked.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
