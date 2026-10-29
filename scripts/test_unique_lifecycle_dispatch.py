from __future__ import annotations

import io
import json
import unittest
from argparse import Namespace
from unittest.mock import patch
from urllib.error import URLError

from assert_unique_lifecycle_dispatch import (
    LIFECYCLE_WORKFLOWS,
    LifecycleDispatchError,
    assert_unique_dispatch_id,
    check_dispatch,
    fetch_workflow_runs,
)


DISPATCH_ID = "a" * 32


class UniqueLifecycleDispatchTests(unittest.TestCase):
    def run_record(self, run_id: int, dispatch_id: str = DISPATCH_ID) -> dict[str, object]:
        return {
            "id": run_id,
            "display_title": f"database/prd-2026-11-01/apply/bootstrap:{dispatch_id}",
        }

    def arguments(
        self, dispatch_id: str = DISPATCH_ID, current_run_attempt: int = 1
    ) -> Namespace:
        return Namespace(
            dispatch_id=dispatch_id,
            repository="owner/repo",
            started_at="2026-11-01T09:00:00Z",
            token="test-token",
            api_url="https://api.github.com",
            current_run_id="202",
            current_run_attempt=current_run_attempt,
        )

    def test_accepts_a_new_dispatch_id(self) -> None:
        assert_unique_dispatch_id(
            runs=[self.run_record(101, "b" * 32)],
            dispatch_id=DISPATCH_ID,
            current_run_id="202",
            current_run_attempt=1,
        )

    def test_rejects_a_dispatch_id_already_used_by_another_run(self) -> None:
        with self.assertRaisesRegex(LifecycleDispatchError, "already used"):
            assert_unique_dispatch_id(
                runs=[self.run_record(101)],
                dispatch_id=DISPATCH_ID,
                current_run_id="202",
                current_run_attempt=1,
            )

    def test_rejects_a_github_rerun_before_querying_history(self) -> None:
        with patch("assert_unique_lifecycle_dispatch.urlopen") as request:
            with self.assertRaisesRegex(LifecycleDispatchError, "reruns are rejected"):
                check_dispatch(self.arguments(current_run_attempt=2))
        request.assert_not_called()

    def test_history_api_failure_fails_closed(self) -> None:
        with patch(
            "assert_unique_lifecycle_dispatch.urlopen",
            side_effect=URLError("offline"),
        ):
            with self.assertRaisesRegex(LifecycleDispatchError, "refusing to continue"):
                check_dispatch(self.arguments())

    def test_failure_on_second_workflow_history_query_fails_closed(self) -> None:
        available_history = io.BytesIO(json.dumps({"workflow_runs": []}).encode("utf-8"))
        with patch(
            "assert_unique_lifecycle_dispatch.urlopen",
            side_effect=[available_history, URLError("offline")],
        ):
            with self.assertRaisesRegex(LifecycleDispatchError, "refusing to continue"):
                check_dispatch(self.arguments())

    def test_duplicate_on_either_lifecycle_workflow_is_rejected(self) -> None:
        empty_history = io.BytesIO(json.dumps({"workflow_runs": []}).encode("utf-8"))
        duplicate_history = io.BytesIO(
            json.dumps({"workflow_runs": [self.run_record(101)]}).encode("utf-8")
        )
        with patch(
            "assert_unique_lifecycle_dispatch.urlopen",
            side_effect=[empty_history, duplicate_history],
        ):
            with self.assertRaisesRegex(LifecycleDispatchError, "already used"):
                check_dispatch(self.arguments())

    def test_history_query_covers_apply_and_destroy_for_the_session_day(self) -> None:
        response = io.BytesIO(json.dumps({"workflow_runs": []}).encode("utf-8"))
        with patch(
            "assert_unique_lifecycle_dispatch.urlopen", return_value=response
        ) as request:
            fetch_workflow_runs(
                repository="owner/repo",
                workflow_file="apply.yml",
                started_at="2026-11-01T09:00:00Z",
                token="test-token",
                api_url="https://api.github.com",
            )

        requested_url = request.call_args.args[0].full_url
        self.assertIn("created=%3E%3D2026-11-01T09%3A00%3A00Z", requested_url)
        self.assertIn("event=workflow_dispatch", requested_url)
        self.assertEqual(LIFECYCLE_WORKFLOWS, ("apply.yml", "destroy.yml"))

    def test_missing_dispatch_id_fails_closed_without_api(self) -> None:
        with patch("assert_unique_lifecycle_dispatch.urlopen") as request:
            with self.assertRaisesRegex(LifecycleDispatchError, "ID is required"):
                check_dispatch(self.arguments(""))
        request.assert_not_called()

    def test_rejects_malformed_dispatch_id(self) -> None:
        with self.assertRaisesRegex(LifecycleDispatchError, "32 lowercase"):
            assert_unique_dispatch_id(
                runs=[],
                dispatch_id="not-a-uuid",
                current_run_id="202",
                current_run_attempt=1,
            )


if __name__ == "__main__":
    unittest.main()
