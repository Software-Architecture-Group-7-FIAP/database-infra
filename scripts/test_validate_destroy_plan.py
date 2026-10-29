from __future__ import annotations

import unittest

from validate_destroy_plan import DestroyPlanError, validate_destroy_plan


def state_fixture() -> dict[str, object]:
    return {
        "values": {
            "root_module": {
                "resources": [
                    {"mode": "managed", "address": "aws_db_instance.this"},
                    {"mode": "data", "address": "data.aws_caller_identity.current"},
                ],
                "child_modules": [
                    {
                        "resources": [
                            {"mode": "managed", "address": "module.secrets.aws_secretsmanager_secret.this"}
                        ],
                        "child_modules": [],
                    }
                ],
            }
        }
    }


def plan_fixture() -> dict[str, object]:
    return {
        "format_version": "1.2",
        "resource_changes": [
            {
                "address": "aws_db_instance.this",
                "mode": "managed",
                "change": {"actions": ["delete"]},
            },
            {
                "address": "module.secrets.aws_secretsmanager_secret.this",
                "mode": "managed",
                "change": {"actions": ["delete"]},
            },
            {
                "address": "data.aws_caller_identity.current",
                "mode": "data",
                "change": {"actions": ["no-op"]},
            },
        ],
    }


class DestroyPlanValidationTests(unittest.TestCase):
    def test_accepts_exact_deletions_for_managed_state(self) -> None:
        validate_destroy_plan(plan_fixture(), state_fixture())

    def test_rejects_create_replace_and_update_actions(self) -> None:
        for actions in (["create"], ["delete", "create"], ["update"]):
            with self.subTest(actions=actions):
                plan = plan_fixture()
                changes = plan["resource_changes"]
                assert isinstance(changes, list)
                changes[0]["change"]["actions"] = list(actions)
                with self.assertRaisesRegex(DestroyPlanError, "plain deletion"):
                    validate_destroy_plan(plan, state_fixture())

    def test_rejects_missing_or_out_of_state_deletions(self) -> None:
        plan = plan_fixture()
        changes = plan["resource_changes"]
        assert isinstance(changes, list)
        changes.pop(0)
        with self.assertRaisesRegex(DestroyPlanError, "exactly cover"):
            validate_destroy_plan(plan, state_fixture())

        plan = plan_fixture()
        changes = plan["resource_changes"]
        assert isinstance(changes, list)
        changes[0]["address"] = "aws_unmanaged_resource.outside"
        with self.assertRaisesRegex(DestroyPlanError, "outside this root's state"):
            validate_destroy_plan(plan, state_fixture())

    def test_rejects_invalid_plan_and_state_shapes(self) -> None:
        with self.assertRaisesRegex(DestroyPlanError, "format version"):
            validate_destroy_plan({"resource_changes": []}, state_fixture())
        with self.assertRaisesRegex(DestroyPlanError, "root module"):
            validate_destroy_plan(plan_fixture(), {"values": {}})


if __name__ == "__main__":
    unittest.main()
