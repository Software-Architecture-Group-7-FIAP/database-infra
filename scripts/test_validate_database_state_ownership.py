import tempfile
import unittest
from pathlib import Path

from database_state_inventory import SHARED_BINDINGS
from validate_database_state_ownership import (
    StateOwnershipError,
    _environment_owned_addresses,
    _environment_requirements,
    _read_addresses,
    validate_all_states,
)


def _legacy_bootstrap_role_parameter(environment: str) -> str:
    return (
        "module.ssm_contract.aws_ssm_parameter.string["
        f'"database/iam/bootstrap-role-arn/{environment}"]'
    )


def _valid_synthetic_states() -> dict[str, set[str]]:
    return {
        "staging": set(SHARED_BINDINGS),
        "hml": _environment_requirements("hml"),
        "prd": _environment_requirements("prd"),
    }


class DatabaseStateOwnershipTests(unittest.TestCase):
    def test_read_addresses_rejects_duplicate_lines_without_exposing_address(self):
        duplicate_address = "aws_iam_role.synthetic_duplicate"
        with tempfile.TemporaryDirectory() as temporary_directory:
            inventory_path = Path(temporary_directory) / "synthetic-inventory.txt"
            inventory_path.write_text(
                f"{duplicate_address}\n{duplicate_address}\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                StateOwnershipError, "duplicate address entries"
            ) as caught:
                _read_addresses(inventory_path, "staging")

        self.assertNotIn(duplicate_address, str(caught.exception))

    def test_legacy_bootstrap_role_parameters_are_not_approved_environment_bindings(
        self,
    ):
        for environment in ("hml", "prd"):
            with self.subTest(environment=environment):
                self.assertNotIn(
                    _legacy_bootstrap_role_parameter(environment),
                    _environment_owned_addresses(environment),
                )

    def test_all_states_reject_legacy_bootstrap_role_parameters(self):
        for environment in ("staging", "hml", "prd"):
            with self.subTest(environment=environment):
                states = _valid_synthetic_states()
                states[environment].add(
                    _legacy_bootstrap_role_parameter(environment)
                )

                with self.assertRaisesRegex(
                    StateOwnershipError,
                    "unexpected legacy bootstrap role ARN SSM parameter",
                ):
                    validate_all_states(
                        states["staging"],
                        states["hml"],
                        states["prd"],
                        allow_empty_environments=False,
                    )


if __name__ == "__main__":
    unittest.main()
