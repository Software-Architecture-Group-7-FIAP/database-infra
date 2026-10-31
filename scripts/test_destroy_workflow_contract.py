import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DESTROY_WORKFLOW = (REPO_ROOT / ".github/workflows/destroy.yml").read_text(
    encoding="utf-8"
)


class DestroyWorkflowContractTests(unittest.TestCase):
    def test_any_unverified_kubernetes_cleanup_blocks_database_destroy(self):
        self.assertIn("--request-timeout=30s", DESTROY_WORKFLOW)
        self.assertIn(
            "python3 scripts/classify_kubernetes_cleanup_failure.py \\",
            DESTROY_WORKFLOW,
        )
        self.assertIn('>> "$GITHUB_STEP_SUMMARY" || true', DESTROY_WORKFLOW)
        self.assertIn(
            'echo "::error::Bootstrap Kubernetes cleanup failed; Terraform destroy remains blocked."',
            DESTROY_WORKFLOW,
        )
        self.assertIn("Terraform destroy plan failed", DESTROY_WORKFLOW)
        classifier_branch = DESTROY_WORKFLOW.split(
            'python3 scripts/classify_kubernetes_cleanup_failure.py', 1
        )[1].split('elif grep -q \'ResourceNotFoundException\'', 1)[0]
        self.assertIn("exit 1", classifier_branch)
        self.assertNotIn("deferred to EKS cluster teardown", classifier_branch)


if __name__ == "__main__":
    unittest.main()
