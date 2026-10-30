import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DESTROY_WORKFLOW = (REPO_ROOT / ".github/workflows/destroy.yml").read_text(
    encoding="utf-8"
)


class DestroyWorkflowContractTests(unittest.TestCase):
    def test_only_confirmed_kubernetes_network_failures_can_defer_cleanup(self):
        self.assertIn("--request-timeout=30s", DESTROY_WORKFLOW)
        self.assertIn(
            'python3 scripts/classify_kubernetes_cleanup_failure.py "$temp_dir/kubernetes-cleanup.log"',
            DESTROY_WORKFLOW,
        )
        self.assertIn("Terraform destroy plan failed", DESTROY_WORKFLOW)


if __name__ == "__main__":
    unittest.main()
