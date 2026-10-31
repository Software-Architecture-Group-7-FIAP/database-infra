#!/usr/bin/env python3
"""Consume a one-use lifecycle dispatch authorization from the DynamoDB ledger."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path
from typing import Any


REPOSITORY = "Software-Architecture-Group-7-FIAP/database-infra"
EXPECTED_WORKFLOWS = {
    "open": "Apply database staging",
    "close": "Destroy database staging",
}
SESSION_PATTERN = re.compile(r"^(hml|prd)-(\d{4}-\d{2}-\d{2})$")
DISPATCH_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
RUN_ID_PATTERN = re.compile(r"^[1-9][0-9]{0,19}$")
ACTOR_PATTERN = re.compile(r"^[A-Za-z0-9-]{1,39}(?:\[bot\])?$")


class AuthorizationError(ValueError):
    """Raised when the lifecycle ledger authorization cannot be proven."""


class ConditionalWriteConflict(AuthorizationError):
    """Raised when another consumer wins the authorization compare-and-swap."""


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise AuthorizationError(f"{name} is required; lifecycle authorization fails closed.")
    return value


def _dynamodb(operation: str, request: dict[str, Any]) -> dict[str, Any]:
    table_name = _required_environment("LIFECYCLE_TABLE_NAME")
    request = {"TableName": table_name, **request}
    with tempfile.TemporaryDirectory(prefix="lifecycle-ledger-") as temporary_directory:
        request_path = Path(temporary_directory) / "request.json"
        request_path.write_text(json.dumps(request, separators=(",", ":")), encoding="utf-8")
        try:
            result = subprocess.run(
                [
                    "aws",
                    "dynamodb",
                    operation,
                    "--cli-input-json",
                    f"file://{request_path}",
                    "--output",
                    "json",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=45,
                env={**os.environ, "AWS_PAGER": ""},
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise AuthorizationError(
                f"DynamoDB {operation} did not complete; lifecycle authorization fails closed."
            ) from error

    if result.returncode != 0:
        if "ConditionalCheckFailedException" in result.stderr:
            raise ConditionalWriteConflict(
                "The lifecycle authorization compare-and-swap did not match."
            )
        raise AuthorizationError(
            f"DynamoDB {operation} was denied or failed; lifecycle authorization fails closed."
        )
    try:
        response = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as error:
        raise AuthorizationError(
            "DynamoDB returned an invalid response; authorization fails closed."
        ) from error
    if not isinstance(response, dict):
        raise AuthorizationError(
            "DynamoDB returned an invalid response; authorization fails closed."
        )
    return response


def _string(value: str) -> dict[str, str]:
    return {"S": value}


def _number(value: int) -> dict[str, str]:
    return {"N": str(value)}


def _decode_item(item: Any) -> dict[str, Any]:
    if not isinstance(item, dict):
        raise AuthorizationError(
            "The lifecycle authorization item is missing; authorization fails closed."
        )
    result: dict[str, Any] = {}
    try:
        for name, value in item.items():
            if not isinstance(value, dict):
                continue
            if "S" in value:
                result[name] = str(value["S"])
            elif "N" in value:
                result[name] = int(value["N"])
            elif "BOOL" in value:
                result[name] = bool(value["BOOL"])
    except (TypeError, ValueError) as error:
        raise AuthorizationError(
            "The lifecycle authorization item is malformed; authorization fails closed."
        ) from error
    return result


def _read_authorization(session_id: str, dispatch_id: str) -> dict[str, Any]:
    response = _dynamodb(
        "get-item",
        {
            "Key": {
                "session_id": _string(session_id),
                "record_key": _string(f"AUTH#DISPATCH#{dispatch_id}"),
            },
            "ConsistentRead": True,
        },
    )
    return _decode_item(response.get("Item"))


def _read_session_state(session_id: str) -> dict[str, Any]:
    response = _dynamodb(
        "get-item",
        {
            "Key": {
                "session_id": _string(session_id),
                "record_key": _string("STATE"),
            },
            "ConsistentRead": True,
        },
    )
    return _decode_item(response.get("Item"))


def _validate_dispatch_actor(authorization: dict[str, Any], session_state: dict[str, Any]) -> str:
    actor = _required_environment("GITHUB_ACTOR")
    triggering_actor = _required_environment("LIFECYCLE_TRIGGERING_ACTOR")
    dispatch_actor = authorization.get("dispatch_actor")
    source_actor = authorization.get("source_actor")
    if triggering_actor != actor:
        raise AuthorizationError("The triggering actor does not match the original workflow actor.")
    if not ACTOR_PATTERN.fullmatch(actor):
        raise AuthorizationError("The GitHub dispatch actor is malformed; authorization fails closed.")
    if not isinstance(dispatch_actor, str) or not ACTOR_PATTERN.fullmatch(dispatch_actor):
        raise AuthorizationError("The authorized cross-repository dispatch actor is missing or malformed.")
    if not isinstance(source_actor, str) or not ACTOR_PATTERN.fullmatch(source_actor):
        raise AuthorizationError("The authorized source operator is missing or malformed.")
    if source_actor != session_state.get("operator"):
        raise AuthorizationError("The authorization source operator does not match the lifecycle session.")
    if actor != dispatch_actor:
        raise AuthorizationError("The GitHub actor does not match the authorized cross-repository actor.")
    return actor


def _canonical_input_hash(inputs: dict[str, str]) -> str:
    canonical = json.dumps(inputs, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _dispatch_inputs() -> dict[str, str]:
    event_path = Path(_required_environment("GITHUB_EVENT_PATH"))
    try:
        event = json.loads(event_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuthorizationError(
            "The workflow dispatch event could not be read; authorization fails closed."
        ) from error
    inputs = event.get("inputs") if isinstance(event, dict) else None
    if not isinstance(inputs, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in inputs.items()
    ):
        raise AuthorizationError(
            "The workflow dispatch inputs are malformed; authorization fails closed."
        )
    return inputs


def _run_identity() -> tuple[str, int]:
    run_id = _required_environment("GITHUB_RUN_ID")
    raw_attempt = _required_environment("GITHUB_RUN_ATTEMPT")
    if not RUN_ID_PATTERN.fullmatch(run_id) or not re.fullmatch(r"[1-9][0-9]*", raw_attempt):
        raise AuthorizationError(
            "The GitHub run identity is malformed; authorization fails closed."
        )
    return run_id, int(raw_attempt)


def _matches_authorization(
    item: dict[str, Any],
    *,
    action: str,
    stage: str,
    workflow: str,
    inputs_hash: str,
    status: str,
) -> bool:
    return (
        item.get("status") == status
        and item.get("action") == action
        and item.get("stage") == stage
        and item.get("target_repository") == REPOSITORY
        and item.get("target_workflow") == workflow
        and item.get("target_ref") == "refs/heads/main"
        and item.get("inputs_sha256") == inputs_hash
    )


def consume_authorization(action: str, session_id: str, dispatch_id: str) -> None:
    if action not in EXPECTED_WORKFLOWS:
        raise AuthorizationError("The expected lifecycle action is invalid.")
    match = SESSION_PATTERN.fullmatch(session_id)
    if match is None or not DISPATCH_ID_PATTERN.fullmatch(dispatch_id):
        raise AuthorizationError("The lifecycle session or dispatch identifier is malformed.")
    try:
        date.fromisoformat(match.group(2))
    except ValueError as error:
        raise AuthorizationError("The lifecycle session date is malformed.") from error

    workflow = EXPECTED_WORKFLOWS[action]
    repository = _required_environment("GITHUB_REPOSITORY")
    event_name = _required_environment("GITHUB_EVENT_NAME")
    current_workflow = _required_environment("GITHUB_WORKFLOW")
    ref = _required_environment("GITHUB_REF")
    if (
        repository != REPOSITORY
        or event_name != "workflow_dispatch"
        or current_workflow != workflow
        or ref != "refs/heads/main"
    ):
        raise AuthorizationError(
            "The consumer repository, workflow, event, or ref is outside the ledger contract."
        )

    inputs = _dispatch_inputs()
    if inputs.get("session_id") != session_id or inputs.get("lifecycle_dispatch_id") != dispatch_id:
        raise AuthorizationError(
            "The dispatch inputs do not match the requested lifecycle authorization."
        )
    expected_input_names = {
        "session_id",
        "started_at",
        "session_mode",
        "phase" if action == "open" else "confirm",
        "lifecycle_dispatch_id",
    }
    if set(inputs) != expected_input_names:
        raise AuthorizationError(
            "The dispatch input set differs from the lifecycle ledger contract."
        )

    run_id, run_attempt = _run_identity()
    stage = match.group(1)
    inputs_hash = _canonical_input_hash(inputs)
    now = int(time.time())
    current = _read_authorization(session_id, dispatch_id)
    session_state = _read_session_state(session_id)
    actor = _validate_dispatch_actor(current, session_state)

    if _matches_authorization(
        current,
        action=action,
        stage=stage,
        workflow=workflow,
        inputs_hash=inputs_hash,
        status="consumed",
    ):
        if (
            current.get("consumer_run_id") == run_id
            and current.get("consumer_run_attempt") == run_attempt
            and current.get("consumer_actor") == actor
        ):
            print(
                "Lifecycle authorization was already consumed by this exact workflow run attempt."
            )
            return
        raise AuthorizationError(
            "The one-use lifecycle authorization was already consumed by another run."
        )

    if not _matches_authorization(
        current,
        action=action,
        stage=stage,
        workflow=workflow,
        inputs_hash=inputs_hash,
        status="issued",
    ) or int(current.get("expires_at", 0)) <= now:
        raise AuthorizationError(
            "The one-use lifecycle authorization is invalid, expired, or mismatched."
        )

    request = {
        "Key": {
            "session_id": _string(session_id),
            "record_key": _string(f"AUTH#DISPATCH#{dispatch_id}"),
        },
        "UpdateExpression": (
            "SET #status = :consumed, consumer_actor = :actor, consumer_run_id = :run, "
            "consumer_run_attempt = :attempt, consumed_at = :now"
        ),
        "ConditionExpression": (
            "#status = :issued AND expires_at > :now AND action = :action AND stage = :stage "
            "AND target_repository = :repository AND target_workflow = :workflow "
            "AND target_ref = :ref AND inputs_sha256 = :inputs_hash AND dispatch_actor = :dispatch_actor"
        ),
        "ExpressionAttributeNames": {"#status": "status"},
        "ExpressionAttributeValues": {
            ":consumed": _string("consumed"),
            ":issued": _string("issued"),
            ":action": _string(action),
            ":stage": _string(stage),
            ":now": _number(now),
            ":repository": _string(REPOSITORY),
            ":workflow": _string(workflow),
            ":ref": _string("refs/heads/main"),
            ":inputs_hash": _string(inputs_hash),
            ":actor": _string(actor),
            ":dispatch_actor": _string(actor),
            ":run": _string(run_id),
            ":attempt": _number(run_attempt),
        },
    }
    try:
        _dynamodb("update-item", request)
    except ConditionalWriteConflict as error:
        current = _read_authorization(session_id, dispatch_id)
        if (
            _matches_authorization(
                current,
                action=action,
                stage=stage,
                workflow=workflow,
                inputs_hash=inputs_hash,
                status="consumed",
            )
            and current.get("consumer_run_id") == run_id
            and current.get("consumer_run_attempt") == run_attempt
            and current.get("consumer_actor") == actor
        ):
            print(
                "Lifecycle authorization was already consumed by this exact workflow run attempt."
            )
            return
        raise AuthorizationError(
            "The one-use lifecycle authorization is invalid, expired, or already consumed."
        ) from error

    print(f"Consumed the {action} authorization for {session_id} in this workflow run attempt.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=tuple(EXPECTED_WORKFLOWS), required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--dispatch-id", required=True)
    args = parser.parse_args()

    try:
        consume_authorization(args.action, args.session_id, args.dispatch_id)
    except (AuthorizationError, TypeError, ValueError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
