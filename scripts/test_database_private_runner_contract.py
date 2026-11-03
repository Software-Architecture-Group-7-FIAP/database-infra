import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DatabasePrivateRunnerContractTests(unittest.TestCase):
    def test_protected_apply_uses_the_database_private_runner_group_and_label(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        expected_label = (
            "codebuild-auto-shop-db-private-${{ github.run_id }}-"
            "${{ github.run_attempt }}"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn(
            "    runs-on:\n"
            "      group: k8s-private-eks\n"
            f"      labels: {expected_label}",
            workflow,
        )

    def test_unprotected_ad_hoc_bootstrap_entry_point_is_removed(self) -> None:
        workflow = ROOT / ".github" / "workflows" / "adhoc-bootstrap.yml"

        self.assertFalse(workflow.exists())


if __name__ == "__main__":
    unittest.main()
