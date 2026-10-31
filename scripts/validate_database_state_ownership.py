#!/usr/bin/env python3
"""Fail closed unless managed database bindings belong to the intended roots."""

import argparse
import re
import sys
from pathlib import Path


class StateOwnershipError(ValueError):
    """Raised when a Terraform state crosses its approved ownership boundary."""


def _read_addresses(path: Path, label: str) -> set[str]:
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as error:
        raise StateOwnershipError(f"{label} Terraform state inventory is unavailable.") from error
    return {line.strip() for line in contents.splitlines() if line.strip()}


def _environment_requirements(environment: str) -> set[str]:
    return {
        f'module.secrets.aws_secretsmanager_secret.runtime["{environment}"]',
        f'module.secrets.aws_secretsmanager_secret.lambda["{environment}"]',
        f'aws_iam_policy.lambda_{environment}_secret_read',
        f'module.ssm_contract.aws_ssm_parameter.string["database/names/{environment}"]',
        f'module.ssm_contract.aws_ssm_parameter.string["database/secrets/runtime-{environment}-arn"]',
        f'module.ssm_contract.aws_ssm_parameter.string["database/secrets/lambda-{environment}-arn"]',
        f'module.ssm_contract.aws_ssm_parameter.string["database/iam/lambda-read-policy-arn/{environment}"]',
    }


def _environment_owned_addresses(environment: str) -> set[str]:
    # Keep the former bootstrap-role SSM binding allowlisted until a guarded
    # apply removes it from migrated state; it is no longer part of the contract.
    return _environment_requirements(environment) | {
        f'module.secrets.aws_secretsmanager_secret.migrations["{environment}"]',
        f'aws_iam_policy.migration_{environment}_secret_read',
        f'aws_iam_policy.bootstrap_{environment}_secret_access',
        'aws_iam_role.environment_bootstrap',
        f'aws_iam_role_policy_attachment.bootstrap_{environment}_secret_access',
        f'module.ssm_contract.aws_ssm_parameter.string["database/secrets/migrations-{environment}-arn"]',
        f'module.ssm_contract.aws_ssm_parameter.string["database/iam/migrations-{environment}-read-policy-arn"]',
        f'module.ssm_contract.aws_ssm_parameter.string["database/iam/bootstrap-role-arn/{environment}"]',
    }


def validate_environment_state(
    environment: str,
    addresses: set[str],
    *,
    allow_empty: bool,
) -> None:
    if not addresses:
        if allow_empty:
            return
        raise StateOwnershipError(f"The {environment} state has no transferred live bindings.")

    missing = _environment_requirements(environment) - addresses
    if missing:
        raise StateOwnershipError(
            f"The {environment} state is missing {len(missing)} required transferred bindings."
        )

    shared_resource_pattern = re.compile(
        r"(?:^|\.)module\.(?:network|instance)\."
        r"|(?:^|\.)aws_(?:db_instance|db_subnet_group|security_group|"
        r"vpc_security_group_[a-z_]+|eks_pod_identity_association)\."
    )
    if any(shared_resource_pattern.search(address) for address in addresses):
        raise StateOwnershipError(
            f"The {environment} state contains a shared database, network, or Pod Identity resource."
        )

    unexpected = addresses - _environment_owned_addresses(environment)
    if unexpected:
        raise StateOwnershipError(
            f"The {environment} state contains {len(unexpected)} address(es) outside its exact approved inventory."
        )

    other_environment = "prd" if environment == "hml" else "hml"
    other_bindings = _environment_owned_addresses(other_environment) - {
        "aws_iam_role.environment_bootstrap"
    }
    if addresses & other_bindings:
        raise StateOwnershipError(f"The {environment} state contains {other_environment} bindings.")


def validate_all_states(
    staging: set[str],
    hml: set[str],
    prd: set[str],
    *,
    allow_empty_environments: bool,
) -> None:
    shared_required = {
        "module.network.aws_db_subnet_group.this",
        "module.network.aws_security_group.this",
        "module.instance.aws_db_parameter_group.this",
        "module.instance.aws_db_instance.this",
        "aws_iam_role.db_bootstrap",
        "aws_iam_role_policy.db_bootstrap",
        "aws_eks_pod_identity_association.db_bootstrap",
        'module.ssm_contract.aws_ssm_parameter.string["database/host"]',
        'module.ssm_contract.aws_ssm_parameter.string["database/port"]',
        'module.ssm_contract.aws_ssm_parameter.string["database/security-group-id"]',
        'module.ssm_contract.aws_ssm_parameter.string["database/secrets/owner-arn"]',
    }
    missing_shared = shared_required - staging
    if missing_shared:
        raise StateOwnershipError(
            f"The shared staging state is missing {len(missing_shared)} required shared bindings."
        )

    environment_addresses = _environment_owned_addresses("hml") | _environment_owned_addresses("prd")
    if staging & environment_addresses:
        raise StateOwnershipError(
            "The shared staging state still owns HML/PRD bindings that must be transferred."
        )

    validate_environment_state("hml", hml, allow_empty=allow_empty_environments)
    validate_environment_state("prd", prd, allow_empty=allow_empty_environments)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=("hml", "prd"))
    parser.add_argument("--state-list", type=Path)
    parser.add_argument("--staging-list", type=Path)
    parser.add_argument("--hml-list", type=Path)
    parser.add_argument("--prd-list", type=Path)
    parser.add_argument("--allow-empty-environments", action="store_true")
    args = parser.parse_args()

    try:
        if args.environment:
            if not args.state_list or any((args.staging_list, args.hml_list, args.prd_list)):
                raise StateOwnershipError(
                    "Environment validation requires --environment and only --state-list."
                )
            validate_environment_state(
                args.environment,
                _read_addresses(args.state_list, args.environment),
                allow_empty=args.allow_empty_environments,
            )
        else:
            if not all((args.staging_list, args.hml_list, args.prd_list)) or args.state_list:
                raise StateOwnershipError(
                    "Full validation requires --staging-list, --hml-list, and --prd-list."
                )
            validate_all_states(
                _read_addresses(args.staging_list, "staging"),
                _read_addresses(args.hml_list, "hml"),
                _read_addresses(args.prd_list, "prd"),
                allow_empty_environments=args.allow_empty_environments,
            )
    except StateOwnershipError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print("Database Terraform state ownership matches the shared/HML/PRD boundary.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
