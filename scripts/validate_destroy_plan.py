#!/usr/bin/env python3
"""Validate that a saved Terraform destroy plan deletes exactly this root's managed state."""

import json
import sys
from pathlib import Path
from typing import Any


class DestroyPlanError(ValueError):
    """Raised when a Terraform destroy plan exceeds the root's managed state."""


def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DestroyPlanError(f"{label} JSON could not be read.") from error
    if not isinstance(value, dict):
        raise DestroyPlanError(f"{label} JSON must contain an object.")
    return value


def _managed_state_addresses(state: dict[str, Any]) -> set[str]:
    values = state.get("values")
    root_module = values.get("root_module") if isinstance(values, dict) else None
    if not isinstance(root_module, dict):
        raise DestroyPlanError("Terraform state JSON has no root module.")

    addresses: set[str] = set()
    pending = [root_module]
    while pending:
        module = pending.pop()
        resources = module.get("resources", [])
        children = module.get("child_modules", [])
        if not isinstance(resources, list) or not isinstance(children, list):
            raise DestroyPlanError("Terraform state JSON has an invalid module shape.")
        for resource in resources:
            if not isinstance(resource, dict):
                raise DestroyPlanError("Terraform state JSON contains an invalid resource.")
            if resource.get("mode") == "managed":
                address = resource.get("address")
                if not isinstance(address, str) or not address:
                    raise DestroyPlanError("A managed state resource has no address.")
                addresses.add(address)
        pending.extend(children)
    return addresses


def validate_destroy_plan(plan: dict[str, Any], state: dict[str, Any]) -> None:
    if not isinstance(plan.get("format_version"), str):
        raise DestroyPlanError("Terraform plan JSON has no supported format version.")
    changes = plan.get("resource_changes")
    if not isinstance(changes, list):
        raise DestroyPlanError("Terraform plan JSON has no resource changes list.")

    expected = _managed_state_addresses(state)
    deleted: set[str] = set()
    for change in changes:
        if not isinstance(change, dict):
            raise DestroyPlanError("Terraform plan JSON contains an invalid resource change.")
        change_detail = change.get("change")
        if not isinstance(change_detail, dict):
            raise DestroyPlanError("Terraform plan JSON contains an invalid change detail.")
        actions = change_detail.get("actions")
        if not isinstance(actions, list) or any(not isinstance(action, str) for action in actions):
            raise DestroyPlanError("Terraform plan JSON contains invalid resource actions.")
        if actions == ["no-op"]:
            continue
        address = change.get("address")
        if change.get("mode") != "managed":
            raise DestroyPlanError("The destroy plan contains an action outside managed resources.")
        if actions != ["delete"]:
            raise DestroyPlanError("Every planned resource action must be a plain deletion.")
        if not isinstance(address, str) or address not in expected:
            raise DestroyPlanError("The destroy plan references a resource outside this root's state.")
        if address in deleted:
            raise DestroyPlanError("The destroy plan contains a duplicate deletion address.")
        deleted.add(address)

    if deleted != expected:
        missing = len(expected - deleted)
        extra = len(deleted - expected)
        raise DestroyPlanError(
            f"The destroy plan does not exactly cover managed state (missing={missing}, extra={extra})."
        )


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate_destroy_plan.py <plan.json> <state.json>", file=sys.stderr)
        return 2
    try:
        plan = _read_json(Path(sys.argv[1]), "Terraform plan")
        state = _read_json(Path(sys.argv[2]), "Terraform state")
        validate_destroy_plan(plan, state)
    except DestroyPlanError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print("Terraform destroy plan deletes exactly the managed resources in this root's state.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
