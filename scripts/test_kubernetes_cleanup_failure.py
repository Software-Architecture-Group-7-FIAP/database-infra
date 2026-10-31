from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import tempfile
import unittest

from classify_kubernetes_cleanup_failure import classify_failure, main


class KubernetesCleanupFailureTests(unittest.TestCase):
    def test_classifies_tcp_timeout_without_authorizing_teardown(self):
        output = "Unable to connect to the server: dial tcp 192.0.2.10:443: i/o timeout"

        self.assertEqual(classify_failure(output), "network_connection_failed")

    def test_classifies_unreachable_route_without_authorizing_teardown(self):
        output = "dial tcp 192.0.2.10:443: connect: no route to host"

        self.assertEqual(classify_failure(output), "network_connection_failed")

    def test_classifies_socket_timeout_without_authorizing_teardown(self):
        output = "dial tcp 192.0.2.10:443: connect: connection timed out"

        self.assertEqual(classify_failure(output), "network_connection_failed")

    def test_classifies_authorization_failures(self):
        output = "Error from server (Forbidden): serviceaccounts is forbidden"

        self.assertEqual(classify_failure(output), "api_rejected_request")

    def test_authorization_failure_wins_when_mixed_with_timeout(self):
        output = (
            "dial tcp 192.0.2.10:443: i/o timeout\n"
            "Error from server (Forbidden): serviceaccounts is forbidden"
        )

        self.assertEqual(classify_failure(output), "api_rejected_request")

    def test_generic_timeout_is_not_classified_as_connection_failure(self):
        self.assertEqual(
            classify_failure("context deadline exceeded"), "request_timed_out"
        )

    def test_classifies_empty_or_server_error_output(self):
        self.assertEqual(classify_failure(""), "diagnostics_unavailable")
        self.assertEqual(
            classify_failure("Error from server (InternalError)"),
            "api_rejected_request",
        )

    def test_main_always_blocks_and_prints_only_sanitized_category(self):
        raw_diagnostic = "Unable to connect: dial tcp 192.0.2.10:443: i/o timeout"
        with tempfile.TemporaryDirectory() as temp_dir:
            diagnostic_file = Path(temp_dir) / "cleanup.log"
            diagnostic_file.write_text(raw_diagnostic, encoding="utf-8")
            output = StringIO()

            with redirect_stdout(output):
                exit_code = main([str(diagnostic_file)])

        self.assertEqual(exit_code, 1)
        self.assertIn("network_connection_failed", output.getvalue())
        self.assertNotIn(raw_diagnostic, output.getvalue())


if __name__ == "__main__":
    unittest.main()
