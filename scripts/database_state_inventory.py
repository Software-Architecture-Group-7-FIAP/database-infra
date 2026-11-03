#!/usr/bin/env python3
"""Print a fixed-label, redacted summary of Terraform state ownership metadata."""

import argparse
import json
import sys
from pathlib import Path


class InventoryError(ValueError):
    """Raised when state metadata cannot be summarized safely."""


SHARED_BINDINGS = {
    "module.network.aws_db_subnet_group.this": "Shared database subnet group",
    "module.network.aws_security_group.this": "Shared database security group",
    'module.network.aws_vpc_security_group_ingress_rule.this["eks-nodes"]': "Shared ingress from EKS nodes",
    'module.network.aws_vpc_security_group_ingress_rule.this["lambda"]': "Shared ingress from Lambda",
    "module.instance.aws_db_parameter_group.this": "Shared database parameter group",
    "module.instance.aws_db_instance.this": "Shared RDS instance",
    "aws_iam_role.db_bootstrap": "Staging shared legacy bootstrap role",
    "aws_iam_role_policy.db_bootstrap": "Staging shared legacy bootstrap inline policy",
    "aws_eks_pod_identity_association.db_bootstrap": "Staging shared legacy bootstrap Pod Identity association",
    'module.ssm_contract.aws_ssm_parameter.string["database/host"]': "Shared SSM database host binding",
    'module.ssm_contract.aws_ssm_parameter.string["database/port"]': "Shared SSM database port binding",
    'module.ssm_contract.aws_ssm_parameter.string["database/security-group-id"]': "Shared SSM database security group binding",
    'module.ssm_contract.aws_ssm_parameter.string["database/secrets/owner-arn"]': "Shared SSM database owner secret ARN binding",
}


def environment_bindings(environment):
    transfers = {
        f'module.secrets.aws_secretsmanager_secret.runtime["{environment}"]': f"{environment.upper()} runtime secret metadata",
        f'module.secrets.aws_secretsmanager_secret.lambda["{environment}"]': f"{environment.upper()} Lambda secret metadata",
        f"aws_iam_policy.lambda_{environment}_secret_read": f"{environment.upper()} Lambda secret read policy",
        f'module.ssm_contract.aws_ssm_parameter.string["database/names/{environment}"]': f"{environment.upper()} database name parameter",
        f'module.ssm_contract.aws_ssm_parameter.string["database/secrets/runtime-{environment}-arn"]': f"{environment.upper()} runtime secret ARN parameter",
        f'module.ssm_contract.aws_ssm_parameter.string["database/secrets/lambda-{environment}-arn"]': f"{environment.upper()} Lambda secret ARN parameter",
        f'module.ssm_contract.aws_ssm_parameter.string["database/iam/lambda-read-policy-arn/{environment}"]': f"{environment.upper()} Lambda policy ARN parameter",
    }
    optional = {
        f'module.secrets.aws_secretsmanager_secret.migrations["{environment}"]': f"{environment.upper()} migration secret metadata",
        f"aws_iam_policy.migration_{environment}_secret_read": f"{environment.upper()} migration secret read policy",
        f"aws_iam_policy.bootstrap_{environment}_secret_access": f"{environment.upper()} bootstrap secret access policy",
        f"aws_iam_role_policy_attachment.bootstrap_{environment}_secret_access": f"{environment.upper()} bootstrap policy attachment",
        f'module.ssm_contract.aws_ssm_parameter.string["database/secrets/migrations-{environment}-arn"]': f"{environment.upper()} migration secret ARN parameter",
        f'module.ssm_contract.aws_ssm_parameter.string["database/iam/migrations-{environment}-read-policy-arn"]': f"{environment.upper()} migration policy ARN parameter",
    }
    return transfers, optional


def legacy_residual_bindings(environment):
    return {
        f'module.ssm_contract.aws_ssm_parameter.string["database/iam/bootstrap-role-arn/{environment}"]': (
            f"{environment.upper()} deprecated bootstrap role ARN parameter (unexpected legacy residual)"
        ),
    }


ENVIRONMENT_BOOTSTRAP_ROLE = "aws_iam_role.environment_bootstrap"
ENVIRONMENT_BOOTSTRAP_ROLE_LABEL = "Environment-specific bootstrap role (HML/PRD only)"
KNOWN_BINDINGS = dict(SHARED_BINDINGS)
LEGACY_RESIDUAL_BINDINGS = {}
for environment_name in ("hml", "prd"):
    transfer_bindings, optional_bindings = environment_bindings(environment_name)
    KNOWN_BINDINGS.update(transfer_bindings)
    KNOWN_BINDINGS.update(optional_bindings)
    LEGACY_RESIDUAL_BINDINGS.update(legacy_residual_bindings(environment_name))
KNOWN_BINDINGS[ENVIRONMENT_BOOTSTRAP_ROLE] = ENVIRONMENT_BOOTSTRAP_ROLE_LABEL
KNOWN_BINDINGS.update(LEGACY_RESIDUAL_BINDINGS)


def _state_address(resource, instance):
    module_path = resource.get("module")
    resource_type = resource.get("type")
    resource_name = resource.get("name")
    if (module_path is not None and not isinstance(module_path, str)) or not isinstance(resource_type, str) or not isinstance(resource_name, str):
        raise InventoryError("Terraform state contains invalid managed resource metadata.")
    address = f"{module_path}.{resource_type}.{resource_name}" if module_path else f"{resource_type}.{resource_name}"
    index_key = instance.get("index_key")
    if "index_key" in instance:
        if isinstance(index_key, str):
            address += "[" + json.dumps(index_key, ensure_ascii=True) + "]"
        elif isinstance(index_key, int) and not isinstance(index_key, bool):
            address += f"[{index_key}]"
        else:
            raise InventoryError("Terraform state contains unsupported managed instance metadata.")
    if "deposed" in instance:
        raise InventoryError("Terraform state contains a deposed managed instance requiring operator review.")
    return address


def read_state(path):
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InventoryError("A pinned Terraform state could not be parsed safely.") from error

    if (
        not isinstance(state, dict)
        or state.get("version") != 4
        or not isinstance(state.get("serial"), int)
        or isinstance(state.get("serial"), bool)
        or state["serial"] < 0
        or not isinstance(state.get("resources"), list)
    ):
        raise InventoryError("Terraform state metadata is incomplete or unsupported.")

    addresses = set()
    managed_count = 0
    for resource in state["resources"]:
        if not isinstance(resource, dict) or resource.get("mode") not in ("managed", "data"):
            raise InventoryError("Terraform state contains invalid resource metadata.")
        if resource.get("mode") != "managed":
            continue
        instances = resource.get("instances")
        if not isinstance(instances, list) or not instances:
            raise InventoryError("Terraform state contains a managed resource without instance metadata.")
        for instance in instances:
            if not isinstance(instance, dict):
                raise InventoryError("Terraform state contains invalid managed instance metadata.")
            address = _state_address(resource, instance)
            if address in addresses:
                raise InventoryError("Terraform state contains a duplicate managed binding.")
            addresses.add(address)
            managed_count += 1

    return state["serial"], addresses, managed_count


def _presence_row(label, address, states):
    values = ["present" if address in states[name]["addresses"] else "absent" for name in ("staging", "hml", "prd")]
    return f"| {label} | {values[0]} | {values[1]} | {values[2]} |"


def build_report(states):
    if ENVIRONMENT_BOOTSTRAP_ROLE in states["staging"]["addresses"]:
        raise InventoryError(
            "The staging state contains an environment-specific bootstrap role that is expected only in HML and PRD."
        )

    lines = [
        "# Redacted database Terraform state inventory",
        "",
        "This report contains state serials, counts, fixed labels, and presence statuses for those labels only. It omits raw resource addresses, values, outputs, secret metadata, object version IDs, and state contents.",
        "",
        "| State | Serial | Managed bindings | Uncatalogued bindings |",
        "|---|---:|---:|---:|",
    ]
    for name in ("staging", "hml", "prd"):
        state = states[name]
        unknown_count = len(state["addresses"] - KNOWN_BINDINGS.keys())
        lines.append(f"| {name} | {state['serial']} | {state['managed_count']} | {unknown_count} |")

    lines.extend(["", "## Shared bindings", "", "| Documented binding | staging | hml | prd |", "|---|---|---|---|"])
    for address, label in SHARED_BINDINGS.items():
        lines.append(_presence_row(label, address, states))

    for environment_name in ("hml", "prd"):
        transfers, optional = environment_bindings(environment_name)
        lines.extend([
            "",
            f"## {environment_name.upper()} transfer bindings",
            "",
            "| Documented binding | staging | hml | prd |",
            "|---|---|---|---|",
        ])
        for address, label in transfers.items():
            lines.append(_presence_row(label, address, states))
        lines.extend([
            "",
            f"## {environment_name.upper()} optional bindings",
            "",
            "| Documented binding | staging | hml | prd |",
            "|---|---|---|---|",
        ])
        for address, label in optional.items():
            lines.append(_presence_row(label, address, states))

    lines.extend([
        "",
        "## Environment-specific bootstrap role",
        "",
        "| Documented binding | staging | hml | prd |",
        "|---|---|---|---|",
        _presence_row(ENVIRONMENT_BOOTSTRAP_ROLE_LABEL, ENVIRONMENT_BOOTSTRAP_ROLE, states),
        "",
        "## Unexpected legacy residual bindings",
        "",
        "| Documented binding | staging | hml | prd |",
        "|---|---|---|---|",
    ])
    for address, label in LEGACY_RESIDUAL_BINDINGS.items():
        lines.append(_presence_row(label, address, states))
    lines.extend([
        "",
        "Uncatalogued bindings are reported only as counts; inspect them through the protected operator procedure before making an ownership decision. This report does not validate ownership or authorize Terraform plans, applies, imports, or state moves.",
        "",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", action="append", required=True, metavar="NAME=PATH")
    args = parser.parse_args()

    expected = {"staging", "hml", "prd"}
    paths = {}
    for entry in args.state:
        if "=" not in entry:
            raise InventoryError("State inputs must name each expected environment exactly once.")
        name, path = entry.split("=", 1)
        if name not in expected or not path or name in paths:
            raise InventoryError("State inputs must name each expected environment exactly once.")
        paths[name] = Path(path)
    if set(paths) != expected:
        raise InventoryError("State inputs must name each expected environment exactly once.")

    states = {}
    for name in ("staging", "hml", "prd"):
        serial, addresses, managed_count = read_state(paths[name])
        states[name] = {"serial": serial, "addresses": addresses, "managed_count": managed_count}
    sys.stdout.write(build_report(states))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InventoryError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
