#!/usr/bin/env python3
"""Restrict HML/PRD destroy plans to exact environment-owned Terraform bindings."""

import sys
from pathlib import Path
from typing import Any

from validate_destroy_plan import (
    DestroyPlanError,
    _managed_state_addresses,
    _read_json,
    validate_destroy_plan,
)


ALLOWED_TYPES = {
    "aws_iam_policy",
    "aws_iam_role",
    "aws_iam_role_policy_attachment",
    "aws_secretsmanager_secret",
    "aws_ssm_parameter",
}


def _approved_resources(environment: str) -> dict[str, tuple[str, dict[str, str]]]:
    if environment not in {"hml", "prd"}:
        raise DestroyPlanError("The selected environment must be hml or prd.")
    role_name = f"auto-shop-staging-db-bootstrap-{environment}"
    names: dict[str, tuple[str, dict[str, str]]] = {
        f'module.secrets.aws_secretsmanager_secret.runtime["{environment}"]': (
            "aws_secretsmanager_secret", {"name": f"auto-shop/staging/{environment}/app-runtime"}
        ),
        f'module.secrets.aws_secretsmanager_secret.lambda["{environment}"]': (
            "aws_secretsmanager_secret", {"name": f"auto-shop/staging/{environment}/lambda-auth"}
        ),
        f'module.secrets.aws_secretsmanager_secret.migrations["{environment}"]': (
            "aws_secretsmanager_secret", {"name": f"auto-shop/staging/{environment}/migrations"}
        ),
        f"aws_iam_policy.lambda_{environment}_secret_read": (
            "aws_iam_policy", {"name": f"auto-shop-staging-db-read-lambda-{environment}"}
        ),
        f"aws_iam_policy.migration_{environment}_secret_read": (
            "aws_iam_policy", {"name": f"auto-shop-staging-db-read-migrations-{environment}"}
        ),
        f"aws_iam_policy.bootstrap_{environment}_secret_access": (
            "aws_iam_policy", {"name": f"auto-shop-staging-db-bootstrap-{environment}-secrets"}
        ),
        "aws_iam_role.environment_bootstrap": (
            "aws_iam_role", {"name": role_name, "path": "/auto-shop/"}
        ),
        f"aws_iam_role_policy_attachment.bootstrap_{environment}_secret_access": (
            "aws_iam_role_policy_attachment",
            {
                "role": role_name,
                "policy_arn": f"arn:aws:iam::035611741563:policy/auto-shop/auto-shop-staging-db-bootstrap-{environment}-secrets",
            },
        ),
    }
    ssm_names = (
        f"database/names/{environment}",
        f"database/secrets/runtime-{environment}-arn",
        f"database/secrets/lambda-{environment}-arn",
        f"database/secrets/migrations-{environment}-arn",
        f"database/iam/lambda-read-policy-arn/{environment}",
        f"database/iam/migrations-{environment}-read-policy-arn",
        f"database/iam/bootstrap-role-arn/{environment}",
    )
    for name in ssm_names:
        address = f'module.ssm_contract.aws_ssm_parameter.string["{name}"]'
        names[address] = ("aws_ssm_parameter", {"name": f"/auto-shop/staging/{name}"})
    return names


def _validate_environment_change(change: dict[str, Any], approved: dict[str, tuple[str, dict[str, str]]]) -> None:
    address = change.get("address")
    if not isinstance(address, str) or address not in approved:
        raise DestroyPlanError("The environment destroy plan contains an unapproved resource address.")
    expected_type, expected_attributes = approved[address]
    if change.get("type") != expected_type:
        raise DestroyPlanError("The environment destroy plan has a resource type/address mismatch.")
    details = change.get("change")
    before = details.get("before") if isinstance(details, dict) else None
    if not isinstance(before, dict):
        raise DestroyPlanError("The environment destroy plan has no resource identity metadata.")
    for attribute, expected in expected_attributes.items():
        if before.get(attribute) != expected:
            raise DestroyPlanError("The environment destroy plan targets a resource with an unapproved name.")


def validate_environment_plan(plan: dict[str, Any], state: dict[str, Any], environment: str) -> None:
    changes = plan.get("resource_changes")
    if not isinstance(changes, list):
        raise DestroyPlanError("Terraform plan JSON has no resource changes list.")

    approved = _approved_resources(environment)
    state_addresses = _managed_state_addresses(state)
    if not state_addresses <= set(approved):
        raise DestroyPlanError("The environment state contains a resource outside its exact approved inventory.")

    for change in changes:
        if not isinstance(change, dict):
            raise DestroyPlanError("Terraform plan JSON contains an invalid resource change.")
        if change.get("mode") == "managed":
            if change.get("type") not in ALLOWED_TYPES:
                raise DestroyPlanError("The environment destroy plan contains an unapproved resource type.")
            _validate_environment_change(change, approved)

    validate_destroy_plan(plan, state)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: validate_environment_destroy_plan.py <hml|prd> <plan.json> <state.json>",
            file=sys.stderr,
        )
        return 2
    try:
        validate_environment_plan(
            _read_json(Path(sys.argv[2]), "Terraform plan"),
            _read_json(Path(sys.argv[3]), "Terraform state"),
            sys.argv[1],
        )
    except DestroyPlanError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print("Environment destroy plan is exact and contains no shared RDS/network resources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
