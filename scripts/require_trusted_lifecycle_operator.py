#!/usr/bin/env python3
"""Fail closed unless this workflow run was triggered by a trusted lifecycle actor."""

import os
import sys


def main() -> int:
    actor = os.environ.get("GITHUB_ACTOR", "")
    triggering_actor = os.environ.get("LIFECYCLE_TRIGGERING_ACTOR", "")
    allowlist = {
        entry.strip()
        for entry in os.environ.get("LIFECYCLE_TRUSTED_OPERATORS", "").split(",")
        if entry.strip()
    }
    if not triggering_actor or triggering_actor != actor:
        print(
            "::error::The triggering actor does not match the original workflow actor; lifecycle authorization fails closed.",
            file=sys.stderr,
        )
        return 1
    if not actor or not allowlist or actor not in allowlist:
        print(
            "::error::The GitHub actor is not in the exact LIFECYCLE_TRUSTED_OPERATORS allowlist.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
