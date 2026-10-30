#!/usr/bin/env python3
"""Fail closed when a database lifecycle dispatch ID has already been used."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


DISPATCH_ID_PATTERN = re.compile(r"[0-9a-f]{32}\Z")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
WORKFLOW_PATTERN = re.compile(r"[A-Za-z0-9_.-]+\Z")
STARTED_AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
LIFECYCLE_WORKFLOWS = ("apply.yml", "destroy.yml")
PAGE_SIZE = 100
MAX_PAGES = 10


class LifecycleDispatchError(ValueError):
    """Raised when a lifecycle dispatch ID cannot be verified as unique."""


def _parse_started_at(value: str) -> datetime:
    try:
        parsed = datetime.strptime(value, STARTED_AT_FORMAT)
    except ValueError as error:
        raise LifecycleDispatchError(
            "The lifecycle session start must use UTC format YYYY-MM-DDTHH:MM:SSZ."
        ) from error
    if parsed.strftime(STARTED_AT_FORMAT) != value:
        raise LifecycleDispatchError(
            "The lifecycle session start must use UTC format YYYY-MM-DDTHH:MM:SSZ."
        )
    return parsed.replace(tzinfo=timezone.utc)


def fetch_workflow_runs(
    *,
    repository: str,
    workflow_file: str,
    started_at: str,
    token: str,
    api_url: str,
) -> list[dict[str, object]]:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise LifecycleDispatchError("GITHUB_REPOSITORY is invalid.")
    if not WORKFLOW_PATTERN.fullmatch(workflow_file):
        raise LifecycleDispatchError("The workflow file name is invalid.")
    if not token.strip():
        raise LifecycleDispatchError(
            "GITHUB_TOKEN is required to verify lifecycle dispatch uniqueness."
        )

    started_at_utc = _parse_started_at(started_at)
    created_after = started_at_utc.strftime(STARTED_AT_FORMAT)
    endpoint = (
        f"{api_url.rstrip('/')}/repos/{repository}/actions/workflows/"
        f"{workflow_file}/runs"
    )
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    collected_runs: list[dict[str, object]] = []
    for page in range(1, MAX_PAGES + 1):
        query = urlencode(
            {
                "branch": "main",
                "created": f">={created_after}",
                "event": "workflow_dispatch",
                "page": str(page),
                "per_page": str(PAGE_SIZE),
            }
        )
        request = Request(f"{endpoint}?{query}", headers=headers)
        try:
            with urlopen(request, timeout=20) as response:
                payload = json.loads(response.read())
        except (
            HTTPError,
            URLError,
            TimeoutError,
            OSError,
            UnicodeError,
            json.JSONDecodeError,
        ) as error:
            raise LifecycleDispatchError(
                "GitHub Actions history is unavailable; refusing to continue without a replay check."
            ) from error

        if not isinstance(payload, dict) or not isinstance(
            payload.get("workflow_runs"), list
        ):
            raise LifecycleDispatchError(
                "GitHub returned an invalid Actions run history response."
            )
        page_runs = payload["workflow_runs"]
        if any(not isinstance(run, dict) for run in page_runs):
            raise LifecycleDispatchError("GitHub returned an invalid Actions run record.")
        collected_runs.extend(page_runs)
        if len(page_runs) < PAGE_SIZE:
            return collected_runs

    raise LifecycleDispatchError(
        "The lifecycle run history exceeded the verification page limit."
    )


def assert_unique_dispatch_id(
    *,
    runs: list[dict[str, object]],
    dispatch_id: str,
    current_run_id: str,
    current_run_attempt: int,
) -> None:
    if not DISPATCH_ID_PATTERN.fullmatch(dispatch_id):
        raise LifecycleDispatchError(
            "The lifecycle dispatch ID must be 32 lowercase hexadecimal characters."
        )
    if not current_run_id.isdecimal() or int(current_run_id) <= 0:
        raise LifecycleDispatchError("GITHUB_RUN_ID must be a positive integer.")
    if isinstance(current_run_attempt, bool) or current_run_attempt < 1:
        raise LifecycleDispatchError("GITHUB_RUN_ATTEMPT must be a positive integer.")
    if current_run_attempt != 1:
        raise LifecycleDispatchError(
            "GitHub Actions reruns are rejected because they could replay a lifecycle dispatch."
        )

    for run in runs:
        run_id = run.get("id")
        title = run.get("display_title")
        if not isinstance(run_id, int) or not isinstance(title, str):
            raise LifecycleDispatchError(
                "GitHub returned an incomplete Actions run record."
            )
        if str(run_id) == current_run_id:
            continue
        if title.rsplit(":", maxsplit=1)[-1] == dispatch_id:
            raise LifecycleDispatchError(
                f"Lifecycle dispatch ID was already used by workflow run {run_id}; refusing replay."
            )


def check_dispatch(arguments: argparse.Namespace) -> int:
    dispatch_id = arguments.dispatch_id
    if not dispatch_id:
        raise LifecycleDispatchError(
            "A coordinator lifecycle dispatch ID is required to verify replay safety."
        )
    if not DISPATCH_ID_PATTERN.fullmatch(dispatch_id):
        raise LifecycleDispatchError(
            "The lifecycle dispatch ID must be 32 lowercase hexadecimal characters."
        )
    if arguments.current_run_attempt != 1:
        raise LifecycleDispatchError(
            "GitHub Actions reruns are rejected because they could replay a lifecycle dispatch."
        )

    runs: list[dict[str, object]] = []
    for workflow_file in LIFECYCLE_WORKFLOWS:
        runs.extend(
            fetch_workflow_runs(
                repository=arguments.repository,
                workflow_file=workflow_file,
                started_at=arguments.started_at,
                token=arguments.token,
                api_url=arguments.api_url,
            )
        )
    assert_unique_dispatch_id(
        runs=runs,
        dispatch_id=dispatch_id,
        current_run_id=arguments.current_run_id,
        current_run_attempt=arguments.current_run_attempt,
    )
    print("The lifecycle dispatch ID is unique across database apply and destroy workflows.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dispatch-id", default=os.environ.get("REQUESTED_LIFECYCLE_DISPATCH_ID", "")
    )
    parser.add_argument(
        "--started-at", default=os.environ.get("REQUESTED_STARTED_AT", "")
    )
    parser.add_argument("--current-run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    parser.add_argument(
        "--current-run-attempt",
        type=int,
        default=int(os.environ.get("GITHUB_RUN_ATTEMPT", "0")),
    )
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument(
        "--api-url", default=os.environ.get("GITHUB_API_URL", "https://api.github.com")
    )
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        return check_dispatch(arguments)
    except LifecycleDispatchError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
