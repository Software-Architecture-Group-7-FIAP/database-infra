from __future__ import annotations

import os
from pathlib import Path
import unittest
from unittest.mock import patch

from consume_lifecycle_authorization import (
    EXPECTED_WORKFLOWS,
    AuthorizationError,
    _validate_dispatch_actor,
)
from require_trusted_lifecycle_operator import main as require_trusted_operator


ROOT = Path(__file__).resolve().parents[1]


class LifecycleAuthorizationActorTests(unittest.TestCase):
    def test_accepts_only_the_configured_cross_repo_actor_bound_to_the_session_operator(self) -> None:
        authorization = {
            "dispatch_actor": "dispatch-bot[bot]",
            "source_actor": "trusted-operator",
        }
        session_state = {"operator": "trusted-operator"}
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRIGGERING_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator,dispatch-bot[bot]",
            },
            clear=False,
        ):
            self.assertEqual(_validate_dispatch_actor(authorization, session_state), "dispatch-bot[bot]")

    def test_rejects_another_allowlisted_dispatcher(self) -> None:
        authorization = {
            "dispatch_actor": "dispatch-bot[bot]",
            "source_actor": "trusted-operator",
        }
        session_state = {"operator": "trusted-operator"}
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "other-operator",
                "LIFECYCLE_TRIGGERING_ACTOR": "other-operator",
                "LIFECYCLE_TRUSTED_OPERATORS": "other-operator,dispatch-bot[bot]",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(AuthorizationError, "does not match the authorized cross-repository actor"):
                _validate_dispatch_actor(authorization, session_state)

    def test_fails_closed_when_dispatch_actor_or_source_operator_is_unbound(self) -> None:
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRIGGERING_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRUSTED_OPERATORS": "dispatch-bot[bot]",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(AuthorizationError, "dispatch actor is missing"):
                _validate_dispatch_actor({"source_actor": "trusted-operator"}, {"operator": "trusted-operator"})

            with self.assertRaisesRegex(AuthorizationError, "source operator does not match"):
                _validate_dispatch_actor(
                    {"dispatch_actor": "dispatch-bot[bot]", "source_actor": "different-operator"},
                    {"operator": "trusted-operator"},
                )

    def test_consumer_rejects_a_different_current_triggering_actor(self) -> None:
        authorization = {
            "dispatch_actor": "dispatch-bot[bot]",
            "source_actor": "trusted-operator",
        }
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRIGGERING_ACTOR": "trusted-operator",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator,dispatch-bot[bot]",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(AuthorizationError, "triggering actor does not match the original workflow actor"):
                _validate_dispatch_actor(authorization, {"operator": "trusted-operator"})

    def test_actor_gate_rejects_a_rerun_before_any_aws_assumption(self) -> None:
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "trusted-operator",
                "LIFECYCLE_TRIGGERING_ACTOR": "untrusted-rerunner",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator",
            },
            clear=False,
        ), patch("sys.argv", ["require_trusted_lifecycle_operator.py"]):
            self.assertEqual(require_trusted_operator(), 1)

    def test_lifecycle_workflows_bind_actor_before_credentials(self) -> None:
        for workflow_name in ("apply.yml", "destroy.yml", "ci.yml"):
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            self.assertIn("LIFECYCLE_TRIGGERING_ACTOR: ${{ github.triggering_actor }}", workflow)
            self.assertLess(
                workflow.index("require_trusted_lifecycle_operator.py"),
                workflow.index("aws-actions/configure-aws-credentials@"),
            )

    def test_database_delivery_is_validation_only_for_branch_events(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "database-delivery.yml").read_text(encoding="utf-8")
        self.assertIn("  pull_request:", workflow)
        self.assertIn("  push:", workflow)
        self.assertNotIn("\n  deploy:", workflow)
        self.assertNotIn("id-token: write", workflow)
        self.assertNotIn("aws-actions/configure-aws-credentials@", workflow)
        self.assertNotRegex(workflow, r"(?m)^\s*terraform[^\n]*\b(plan|apply|destroy|state list)\b")

    def test_database_apply_is_hml_only_and_consumes_one_use_authorization(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.splitlines()[0], f"name: {EXPECTED_WORKFLOWS['open']}")
        self.assertIn("options: [hml]", workflow)
        self.assertNotIn("prd-window", workflow)
        self.assertIn("TARGET_ENVIRONMENT: hml", workflow)
        self.assertIn("DATABASE_INFRA_STATE_HANDOFF_COMPLETE", workflow)
        self.assertIn("DATABASE_INFRA_DEPLOYMENT_READY", workflow)
        self.assertLess(
            workflow.index("scripts/require_trusted_lifecycle_operator.py"),
            workflow.index("aws-actions/configure-aws-credentials@"),
        )
        self.assertLess(
            workflow.index("scripts/consume_lifecycle_authorization.py"),
            workflow.index("role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}"),
        )
        self.assertIn("--action open", workflow)

    def test_database_teardown_workflow_name_matches_close_authorization(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.splitlines()[0], f"name: {EXPECTED_WORKFLOWS['close']}")

    def test_hml_oidc_trust_targets_the_manual_lifecycle_workflows(self) -> None:
        trust = (ROOT / ".github" / "oidc" / "hml-trust-policy.json").read_text(encoding="utf-8")
        self.assertIn("environment:staging:workflow_ref:", trust)
        self.assertIn("/.github/workflows/apply.yml@refs/heads/main", trust)
        self.assertIn("/.github/workflows/destroy.yml@refs/heads/main", trust)
        self.assertFalse((ROOT / ".github" / "oidc" / "production-trust-policy.json").exists())


if __name__ == "__main__":
    unittest.main()
