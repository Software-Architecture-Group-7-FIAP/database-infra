#!/usr/bin/env python3
from __future__ import annotations

import unittest

from validate_database_state_ownership import StateOwnershipError, _environment_owned_addresses
from validate_environment_destroy_plan import (
    _approved_resources,
    validate_environment_plan,
)
from validate_destroy_plan import DestroyPlanError


def fixtures(environment: str) -> tuple[dict[str, object], dict[str, object]]:
    approved = _approved_resources(environment)
    resources = [
        {"mode": "managed", "address": address}
        for address in approved
    ]
    changes = [
        {
            "address": address,
            "mode": "managed",
            "type": resource_type,
            "change": {"actions": ["delete"], "before": attributes},
        }
        for address, (resource_type, attributes) in approved.items()
    ]
    return (
        {"values": {"root_module": {"resources": resources}}},
        {"format_version": "1.2", "resource_changes": changes},
    )


class EnvironmentDestroyPlanTests(unittest.TestCase):
    def test_accepts_exact_environment_names_and_addresses(self) -> None:
        for environment in ("hml", "prd"):
            with self.subTest(environment=environment):
                state, plan = fixtures(environment)
                validate_environment_plan(plan, state, environment)

    def test_rejects_wrong_environment_state(self) -> None:
        state, plan = fixtures("hml")
        resources = state["values"]["root_module"]["resources"]
        resources.append({"mode": "managed", "address": 'module.secrets.aws_secretsmanager_secret.runtime["prd"]'})
        with self.assertRaisesRegex(DestroyPlanError, "exact approved inventory"):
            validate_environment_plan(plan, state, "hml")

    def test_rejects_wrong_resource_name(self) -> None:
        state, plan = fixtures("hml")
        changes = plan["resource_changes"]
        next(change for change in changes if change["type"] == "aws_secretsmanager_secret")["change"]["before"]["name"] = "auto-shop/staging/prd/app-runtime"
        with self.assertRaisesRegex(DestroyPlanError, "unapproved name"):
            validate_environment_plan(plan, state, "hml")

    def test_rejects_shared_and_unapproved_addresses(self) -> None:
        state, plan = fixtures("prd")
        changes = plan["resource_changes"]
        changes[0]["address"] = "module.instance.aws_db_instance.this"
        with self.assertRaisesRegex(DestroyPlanError, "unapproved resource address"):
            validate_environment_plan(plan, state, "prd")

    def test_state_contract_allows_environment_role_but_not_shared_role_or_association(self) -> None:
        allowed = _environment_owned_addresses("hml")
        self.assertIn("aws_iam_role.environment_bootstrap", allowed)
        self.assertNotIn("aws_eks_pod_identity_association.environment_bootstrap", allowed)
        self.assertNotIn("aws_iam_role.db_bootstrap", allowed)


if __name__ == "__main__":
    unittest.main()
