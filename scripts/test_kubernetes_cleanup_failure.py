import unittest

from classify_kubernetes_cleanup_failure import is_network_unreachable


class KubernetesCleanupFailureTests(unittest.TestCase):
    def test_classifies_tcp_timeout_as_unreachable(self):
        output = "Unable to connect to the server: dial tcp 192.0.2.10:443: i/o timeout"

        self.assertTrue(is_network_unreachable(output))

    def test_classifies_unreachable_route_as_network_failure(self):
        output = "dial tcp 192.0.2.10:443: connect: no route to host"

        self.assertTrue(is_network_unreachable(output))

    def test_classifies_socket_timeout_as_network_failure(self):
        output = "dial tcp 192.0.2.10:443: connect: connection timed out"

        self.assertTrue(is_network_unreachable(output))

    def test_does_not_skip_authorization_failures(self):
        output = "Error from server (Forbidden): serviceaccounts is forbidden"

        self.assertFalse(is_network_unreachable(output))

    def test_authorization_failure_wins_when_mixed_with_timeout(self):
        output = (
            "dial tcp 192.0.2.10:443: i/o timeout\n"
            "Error from server (Forbidden): serviceaccounts is forbidden"
        )

        self.assertFalse(is_network_unreachable(output))

    def test_does_not_skip_empty_or_server_error_output(self):
        self.assertFalse(is_network_unreachable(""))
        self.assertFalse(is_network_unreachable("Error from server (InternalError)"))


if __name__ == "__main__":
    unittest.main()
