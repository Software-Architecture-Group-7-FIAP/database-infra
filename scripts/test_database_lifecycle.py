from __future__ import annotations

import unittest
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from validate_database_lifecycle import LifecycleWindowError, validate_database_action


BRT = ZoneInfo("America/Sao_Paulo")
DISPATCH_ID = "a" * 32


def utc_timestamp(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=BRT).astimezone(timezone.utc)


class DatabaseLifecycleValidationTests(unittest.TestCase):
    def environment(self, session_mode: str = "hml") -> dict[str, str]:
        values = {
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/main",
            "STAGING_ACTIVE": "true",
            "STAGING_SESSION_AUTHORIZED": "true",
            "STAGING_SESSION_MODE": session_mode,
        }
        if session_mode == "prd-window":
            values.update(
                {
                    "ENVIRONMENT_SCHEDULE_ENABLED": "true",
                    "PRD_LIFECYCLE_AUTOMATION_READY": "true",
                    "PRD_COST_EXCEPTION_APPROVED": "true",
                }
            )
        return values

    def validate(
        self,
        *,
        session_mode: str,
        action: str,
        phase: str,
        session_id: str,
        started_at: str,
        now: datetime,
        confirmation: str = "",
        environment: dict[str, str] | None = None,
        minimum_remaining_seconds: int = 0,
    ) -> None:
        validate_database_action(
            environment if environment is not None else self.environment(session_mode),
            action=action,
            phase=phase,
            session_id=session_id,
            started_at_value=started_at,
            session_mode=session_mode,
            lifecycle_dispatch_id=DISPATCH_ID,
            confirmation=confirmation,
            minimum_remaining_seconds=minimum_remaining_seconds,
            now=now,
        )

    def test_accepts_hml_open_and_teardown_windows(self) -> None:
        start = "2026-10-29T10:00:00Z"
        session_id = "hml-2026-10-29"
        self.validate(
            session_mode="hml",
            action="start",
            phase="bootstrap",
            session_id=session_id,
            started_at=start,
            now=utc_timestamp(2026, 10, 29, 10, 10),
        )
        self.validate(
            session_mode="hml",
            action="start",
            phase="provision",
            session_id="hml-2026-11-01",
            started_at="2026-11-01T20:00:00Z",
            now=utc_timestamp(2026, 11, 1, 17, 30),
        )
        self.validate(
            session_mode="hml",
            action="start",
            phase="bootstrap",
            session_id="hml-2026-11-01",
            started_at="2026-11-01T20:00:00Z",
            now=utc_timestamp(2026, 11, 1, 18, 0),
        )
        self.validate(
            session_mode="hml",
            action="teardown",
            phase="",
            session_id=session_id,
            started_at=start,
            now=utc_timestamp(2026, 10, 29, 12, 30),
            confirmation="destroy",
        )

    def test_rejects_prd_database_apply_during_the_hml_cap_window(self) -> None:
        start = "2026-11-01T09:00:00Z"
        session_id = "prd-2026-11-01"
        for phase in ("provision", "bootstrap", "grants"):
            with self.subTest(phase=phase):
                with self.assertRaisesRegex(LifecycleWindowError, "PRD database apply is disabled"):
                    self.validate(
                        session_mode="prd-window",
                        action="start",
                        phase=phase,
                        session_id=session_id,
                        started_at=start,
                        now=utc_timestamp(2026, 11, 1, 6, 45),
                    )

    def test_prd_grants_after_bootstrap_are_still_disabled(self) -> None:
        with self.assertRaisesRegex(LifecycleWindowError, "PRD database apply is disabled"):
            self.validate(
                session_mode="prd-window",
                action="start",
                phase="grants",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=utc_timestamp(2026, 11, 1, 10, 59),
            )

    def test_hml_teardown_requires_time_before_the_global_cutoff(self) -> None:
        start = "2026-10-29T10:00:00Z"
        session_id = "hml-2026-10-29"
        self.validate(
            session_mode="hml",
            action="teardown",
            phase="",
            session_id=session_id,
            started_at=start,
            now=utc_timestamp(2026, 10, 29, 22, 4),
            confirmation="destroy",
            minimum_remaining_seconds=2100,
        )
        with self.assertRaisesRegex(LifecycleWindowError, "insufficient time"):
            self.validate(
                session_mode="hml",
                action="teardown",
                phase="",
                session_id=session_id,
                started_at=start,
                now=utc_timestamp(2026, 10, 29, 22, 5),
                confirmation="destroy",
                minimum_remaining_seconds=2100,
            )

    def test_prd_teardown_stops_before_audit_and_handoff_windows(self) -> None:
        start = "2026-11-01T09:00:00Z"
        session_id = "prd-2026-11-01"
        self.validate(
            session_mode="prd-window",
            action="teardown",
            phase="",
            session_id=session_id,
            started_at=start,
            now=utc_timestamp(2026, 11, 1, 22, 4),
            confirmation="destroy",
            minimum_remaining_seconds=2100,
        )
        with self.assertRaisesRegex(LifecycleWindowError, "insufficient time"):
            self.validate(
                session_mode="prd-window",
                action="teardown",
                phase="",
                session_id=session_id,
                started_at=start,
                now=utc_timestamp(2026, 11, 1, 22, 5),
                confirmation="destroy",
                minimum_remaining_seconds=2100,
            )
        for minute in (40, 45):
            with self.subTest(minute=minute):
                with self.assertRaisesRegex(LifecycleWindowError, "22:40 BRT same-day cutoff"):
                    self.validate(
                        session_mode="prd-window",
                        action="teardown",
                        phase="",
                        session_id=session_id,
                        started_at=start,
                        now=utc_timestamp(2026, 11, 1, 22, minute),
                        confirmation="destroy",
                    )

    def test_prd_readiness_flags_cannot_reenable_database_apply(self) -> None:
        start = "2026-11-01T09:00:00Z"
        environment = self.environment("prd-window")
        environment["PRD_COST_EXCEPTION_APPROVED"] = "false"
        with self.assertRaisesRegex(LifecycleWindowError, "PRD database apply is disabled"):
            self.validate(
                session_mode="prd-window",
                action="start",
                phase="bootstrap",
                session_id="prd-2026-11-01",
                started_at=start,
                now=utc_timestamp(2026, 11, 1, 6, 45),
                environment=environment,
            )

    def test_rejects_wrong_event_branch_confirmation_and_window(self) -> None:
        start = "2026-11-01T09:00:00Z"
        base = {
            "session_mode": "prd-window",
            "action": "teardown",
            "phase": "",
            "session_id": "prd-2026-11-01",
            "started_at": start,
            "now": utc_timestamp(2026, 11, 1, 22, 15),
        }
        for environment, expected_message in (
            ({**self.environment("prd-window"), "GITHUB_EVENT_NAME": "push"}, "workflow_dispatch"),
            ({**self.environment("prd-window"), "GITHUB_REF": "refs/heads/develop"}, "restricted to main"),
        ):
            with self.subTest(expected_message=expected_message):
                with self.assertRaisesRegex(LifecycleWindowError, expected_message):
                    self.validate(**base, environment=environment)

        with self.assertRaisesRegex(LifecycleWindowError, "exactly"):
            self.validate(**base, confirmation="remove")
        with self.assertRaisesRegex(LifecycleWindowError, "after session start"):
            self.validate(**{**base, "now": utc_timestamp(2026, 11, 1, 5, 59)}, confirmation="destroy")

    def test_teardown_remains_authorized_after_opening_flags_are_revoked(self) -> None:
        environment = self.environment("prd-window")
        environment.update(
            {
                "STAGING_ACTIVE": "false",
                "STAGING_SESSION_AUTHORIZED": "false",
                "STAGING_SESSION_MODE": "hml",
                "ENVIRONMENT_SCHEDULE_ENABLED": "false",
                "PRD_LIFECYCLE_AUTOMATION_READY": "false",
                "PRD_COST_EXCEPTION_APPROVED": "false",
            }
        )
        self.validate(
            session_mode="prd-window",
            action="teardown",
            phase="",
            session_id="prd-2026-11-01",
            started_at="2026-11-01T09:00:00Z",
            now=utc_timestamp(2026, 11, 1, 22, 15),
            confirmation="destroy",
            environment=environment,
        )


if __name__ == "__main__":
    unittest.main()
