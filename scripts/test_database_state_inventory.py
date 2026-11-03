import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from database_state_inventory import (
    ENVIRONMENT_BOOTSTRAP_ROLE,
    ENVIRONMENT_BOOTSTRAP_ROLE_LABEL,
    SHARED_BINDINGS,
    InventoryError,
    build_report,
    read_state,
)
from validate_s3_state_metadata import (
    StateMetadataError,
    read_head_object_metadata,
    validate_head_object_metadata,
)

ROOT = Path(__file__).resolve().parents[1]


class S3StateMetadataTests(unittest.TestCase):
    def test_valid_version_and_length_are_returned(self):
        self.assertEqual(
            validate_head_object_metadata(
                {"VersionId": "state-version-123", "ContentLength": 2048}
            ),
            ("state-version-123", 2048),
        )

    def test_missing_empty_and_null_versions_are_rejected(self):
        invalid_metadata = (
            {"ContentLength": 1},
            {"VersionId": None, "ContentLength": 1},
            {"VersionId": "", "ContentLength": 1},
            {"VersionId": "null", "ContentLength": 1},
            {"VersionId": "None", "ContentLength": 1},
            {"VersionId": "version\nsuffix", "ContentLength": 1},
        )

        for metadata in invalid_metadata:
            with self.subTest(metadata=metadata), self.assertRaises(
                StateMetadataError
            ):
                validate_head_object_metadata(metadata)

    def test_invalid_content_length_is_rejected(self):
        for length in (None, True, -1, 1.5, "1024"):
            with self.subTest(length=length), self.assertRaises(
                StateMetadataError
            ):
                validate_head_object_metadata(
                    {"VersionId": "state-version-123", "ContentLength": length}
                )

    def test_metadata_file_is_parsed_without_exposing_values(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            metadata_path = Path(temporary_directory) / "head-object.json"
            metadata_path.write_text(
                json.dumps(
                    {"VersionId": "state-version-456", "ContentLength": 4096}
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                read_head_object_metadata(metadata_path),
                ("state-version-456", 4096),
            )

    def test_metadata_cli_rejects_null_before_returning_a_version(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            metadata_path = Path(temporary_directory) / "head-object.json"
            metadata_path.write_text(
                json.dumps({"VersionId": "null", "ContentLength": 4096}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "validate_s3_state_metadata.py"),
                    str(metadata_path),
                ],
                capture_output=True,
                check=False,
                text=True,
            )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("null", result.stderr)


class DatabaseStateInventorySummaryTests(unittest.TestCase):
    def test_summarizer_uses_fixed_labels_and_hides_values_and_addresses(self):
        state_document = {
            "version": 4,
            "serial": 7,
            "resources": [
                {
                    "mode": "managed",
                    "module": "module.secrets",
                    "type": "aws_secretsmanager_secret",
                    "name": "runtime",
                    "instances": [
                        {
                            "index_key": "hml",
                            "attributes": {
                                "secret_string": "TEST_SECRET_VALUE_MUST_NOT_APPEAR"
                            },
                        }
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            state_path = Path(temporary_directory) / "hml.tfstate"
            state_path.write_text(json.dumps(state_document), encoding="utf-8")
            serial, addresses, managed_count = read_state(state_path)

        self.assertEqual(serial, 7)
        self.assertEqual(
            addresses,
            {'module.secrets.aws_secretsmanager_secret.runtime["hml"]'},
        )
        self.assertEqual(managed_count, 1)

        hml_residual = (
            'module.ssm_contract.aws_ssm_parameter.string["database/iam/bootstrap-role-arn/hml"]'
        )
        prd_residual = (
            'module.ssm_contract.aws_ssm_parameter.string["database/iam/bootstrap-role-arn/prd"]'
        )
        unknown_address = "aws_iam_user.unexpected_canary"
        states = {
            "staging": {
                "serial": 7,
                "addresses": set(SHARED_BINDINGS),
                "managed_count": len(SHARED_BINDINGS),
            },
            "hml": {
                "serial": 2,
                "addresses": {
                    *addresses,
                    ENVIRONMENT_BOOTSTRAP_ROLE,
                    hml_residual,
                    unknown_address,
                },
                "managed_count": 4,
            },
            "prd": {
                "serial": 3,
                "addresses": {ENVIRONMENT_BOOTSTRAP_ROLE, prd_residual},
                "managed_count": 2,
            },
        }

        report = build_report(states)

        self.assertIn(
            "| Staging shared legacy bootstrap role | present | absent | absent |",
            report,
        )
        self.assertIn(
            f"| {ENVIRONMENT_BOOTSTRAP_ROLE_LABEL} | absent | present | present |",
            report,
        )
        self.assertIn(
            "| HML deprecated bootstrap role ARN parameter (unexpected legacy residual) | absent | present | absent |",
            report,
        )
        self.assertIn(
            "| PRD deprecated bootstrap role ARN parameter (unexpected legacy residual) | absent | absent | present |",
            report,
        )
        self.assertIn("| hml | 2 | 4 | 1 |", report)
        self.assertNotIn("TEST_SECRET_VALUE_MUST_NOT_APPEAR", report)
        self.assertNotIn(unknown_address, report)
        self.assertNotIn("aws_iam_role.environment_bootstrap", report)
        self.assertNotIn("bootstrap-role-arn", report)
        self.assertNotIn("module.secrets.aws_secretsmanager_secret.runtime", report)

    def test_environment_bootstrap_role_in_staging_fails_closed(self):
        states = {
            "staging": {
                "serial": 1,
                "addresses": {ENVIRONMENT_BOOTSTRAP_ROLE},
                "managed_count": 1,
            },
            "hml": {"serial": 1, "addresses": set(), "managed_count": 0},
            "prd": {"serial": 1, "addresses": set(), "managed_count": 0},
        }

        with self.assertRaisesRegex(
            InventoryError,
            "staging state contains an environment-specific bootstrap role",
        ) as caught:
            build_report(states)

        self.assertNotIn(ENVIRONMENT_BOOTSTRAP_ROLE, str(caught.exception))


class DatabaseStateInventoryWorkflowContractTests(unittest.TestCase):
    def test_inventory_workflow_is_main_only_read_only_and_version_pinned(self):
        workflow = (
            ROOT / ".github" / "workflows" / "database-state-inventory.yml"
        ).read_text(encoding="utf-8")

        for expected in (
            "workflow_dispatch:",
            "if: github.ref == 'refs/heads/main'",
            "environment: aws-plan",
            "expected_role_arn=\"arn:aws:iam::035611741563:role/auto-shop/gh-plan-database-infra\"",
            'key="database-infra/$environment/terraform.tfstate"',
            "aws s3api head-object",
            "--query '{VersionId: VersionId, ContentLength: ContentLength}'",
            "scripts/validate_s3_state_metadata.py",
            "aws s3api get-object",
            '--version-id "$version_id"',
            'if [[ "$downloaded_version" != "$version_id" ]]',
            "umask 077",
            'chmod 700 "$temp_dir"',
            "trap 'rm -rf -- \"$temp_dir\"' EXIT",
            'chmod 600 "$state_file"',
            '>> "$GITHUB_STEP_SUMMARY"',
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, workflow)

        self.assertNotIn("actions/upload-artifact", workflow)
        self.assertNotIn("cat \"$state_file\"", workflow)
        self.assertNotIn("terraform apply", workflow)
        self.assertLess(
            workflow.index("scripts/validate_s3_state_metadata.py"),
            workflow.index("aws s3api get-object"),
        )

    def test_runbook_explains_ephemeral_full_state_processing_and_iam_dependency(self):
        runbook = (ROOT / ".github" / "database-state-inventory.md").read_text(
            encoding="utf-8"
        )

        for expected in (
            "each complete state object",
            "absent, empty, or literal",
            "runner-local temporary directory",
            "does not retain state after cleanup or upload artifacts",
            "aws_iam_role.db_bootstrap",
            "aws_iam_role.environment_bootstrap",
            "unexpected residual",
            "**k8s-infra** repository",
            "**envs/staging/bootstrap**",
            "Updating only this repository's JSON does not grant access",
            "Do not dispatch this inventory",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, runbook)


if __name__ == "__main__":
    unittest.main()
