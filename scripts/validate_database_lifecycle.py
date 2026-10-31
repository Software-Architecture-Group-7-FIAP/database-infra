#!/usr/bin/env python3
"""Fail closed unless a protected HML apply or authorized database teardown is in-window."""

import argparse
import os
import re
import sys
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo


BRT = ZoneInfo("America/Sao_Paulo")
FIRST_PRD_DAY = date(2026, 11, 1)
LAST_PRD_DAY = date(2026, 11, 5)
LAST_HML_DAY = date(2026, 11, 5)
STARTED_AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
MAX_SESSION_DURATION = timedelta(hours=5)
LIFECYCLE_TEARDOWN_CUTOFF = time(22, 40)


class LifecycleWindowError(ValueError):
    """Raised when a database lifecycle action is not authorized."""


def _parse_started_at(value: str) -> datetime:
    try:
        started_at = datetime.strptime(value, STARTED_AT_FORMAT).replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise LifecycleWindowError(
            "started_at must use UTC format YYYY-MM-DDTHH:MM:SSZ."
        ) from error
    if started_at.strftime(STARTED_AT_FORMAT) != value:
        raise LifecycleWindowError(
            "started_at must use UTC format YYYY-MM-DDTHH:MM:SSZ."
        )
    return started_at


def _validate_hml_action(
    *,
    action: str,
    phase: str,
    session_id: str,
    started_at: datetime,
    now: datetime,
    confirmation: str,
    minimum_remaining: timedelta,
) -> None:
    local_now = now.astimezone(BRT)
    local_start = started_at.astimezone(BRT)
    if local_now.date() > LAST_HML_DAY or local_start.date() > LAST_HML_DAY:
        raise LifecycleWindowError("HML lifecycle sessions are allowed only through 05/11/2026 BRT.")
    if local_start.date() != local_now.date():
        raise LifecycleWindowError("HML session start and action must use the same BRT date.")
    if session_id != f"hml-{local_now.date().isoformat()}":
        raise LifecycleWindowError("HML session_id must be hml-YYYY-MM-DD for the current BRT date.")
    start_time = local_start.time().replace(tzinfo=None)
    if start_time < time(7, 0) or start_time > time(17, 0):
        raise LifecycleWindowError("HML session start must be between 07:00 and 17:00 BRT.")

    elapsed = now - started_at
    if elapsed < timedelta(0):
        raise LifecycleWindowError("The HML session cannot start in the future.")

    if action == "start":
        if phase not in {"provision", "bootstrap", "grants"}:
            raise LifecycleWindowError("HML apply requires phase provision, bootstrap, or grants.")
        if elapsed >= MAX_SESSION_DURATION:
            raise LifecycleWindowError("HML apply must finish within five hours of started_at.")
        if confirmation:
            raise LifecycleWindowError("A confirmation value is not valid for the apply operation.")
        return

    if action != "teardown":
        raise LifecycleWindowError("Unsupported HML lifecycle action.")
    if phase:
        raise LifecycleWindowError("A phase value is not valid for the teardown operation.")
    if confirmation != "destroy":
        raise LifecycleWindowError('The teardown confirmation must be exactly "destroy".')

    teardown_start = started_at
    teardown_deadline = datetime.combine(
        local_now.date(), LIFECYCLE_TEARDOWN_CUTOFF, BRT
    ).astimezone(timezone.utc)
    if now < teardown_start or now >= teardown_deadline:
        raise LifecycleWindowError(
            "HML teardown is allowed after the session starts and before the 22:40 BRT same-day cutoff."
        )
    if now + minimum_remaining >= teardown_deadline:
        raise LifecycleWindowError(
            "HML teardown has insufficient time to finish before the 22:40 BRT same-day cutoff."
        )


def _validate_prd_action(
    *,
    action: str,
    phase: str,
    session_id: str,
    started_at: datetime,
    now: datetime,
    confirmation: str,
    minimum_remaining: timedelta,
) -> None:
    local_now = now.astimezone(BRT)
    local_start = started_at.astimezone(BRT)
    if not FIRST_PRD_DAY <= local_now.date() <= LAST_PRD_DAY:
        raise LifecycleWindowError(
            "PRD lifecycle actions are allowed only from 01/11/2026 through 05/11/2026 BRT."
        )
    if session_id != f"prd-{local_now.date().isoformat()}":
        raise LifecycleWindowError("PRD session_id must be prd-YYYY-MM-DD for the current BRT date.")
    if local_start.date() != local_now.date() or local_start.time().replace(
        tzinfo=None
    ) != time(6, 0):
        raise LifecycleWindowError("PRD started_at must be 06:00 BRT on the session date.")

    if action != "teardown":
        raise LifecycleWindowError("PRD database apply is disabled during the HML spend-cap window.")
    if phase:
        raise LifecycleWindowError("A phase value is not valid for the teardown operation.")
    if confirmation != "destroy":
        raise LifecycleWindowError('The teardown confirmation must be exactly "destroy".')
    teardown_deadline = datetime.combine(
        local_now.date(), LIFECYCLE_TEARDOWN_CUTOFF, BRT
    ).astimezone(timezone.utc)
    if now < started_at or now >= teardown_deadline:
        raise LifecycleWindowError("PRD database teardown is allowed after session start and before the 22:40 BRT same-day cutoff.")
    if now + minimum_remaining >= teardown_deadline:
        raise LifecycleWindowError(
            "PRD teardown has insufficient time to finish before the 22:40 BRT audit cutoff."
        )


def validate_database_action(
    environment: dict[str, str],
    *,
    action: str,
    phase: str,
    session_id: str,
    started_at_value: str,
    session_mode: str,
    lifecycle_dispatch_id: str,
    confirmation: str,
    minimum_remaining_seconds: int,
    now: datetime,
) -> None:
    if now.tzinfo is None or now.utcoffset() != timedelta(0):
        raise LifecycleWindowError("The current time must be UTC-aware.")
    if (
        isinstance(minimum_remaining_seconds, bool)
        or not isinstance(minimum_remaining_seconds, int)
        or minimum_remaining_seconds < 0
        or minimum_remaining_seconds > 3600
    ):
        raise LifecycleWindowError("minimum_remaining_seconds must be an integer from 0 to 3600.")
    if environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise LifecycleWindowError("Only an explicit workflow_dispatch is accepted.")
    if environment.get("GITHUB_REF") != "refs/heads/main":
        raise LifecycleWindowError("Database lifecycle actions are restricted to main.")
    if session_mode not in {"hml", "prd-window"}:
        raise LifecycleWindowError("session_mode must be hml or prd-window.")
    if not re.fullmatch(r"[0-9a-f]{32}", lifecycle_dispatch_id):
        raise LifecycleWindowError("lifecycle_dispatch_id must be a lowercase 32-character UUID hex value.")
    if action == "start" and session_mode != "hml":
        raise LifecycleWindowError("PRD database apply is disabled during the HML spend-cap window.")

    if action == "start":
        if environment.get("STAGING_ACTIVE") != "true":
            raise LifecycleWindowError("STAGING_ACTIVE must be true to open a database session.")
        if environment.get("STAGING_SESSION_AUTHORIZED") != "true":
            raise LifecycleWindowError("STAGING_SESSION_AUTHORIZED must be true to open a database session.")
        if environment.get("STAGING_SESSION_MODE") != session_mode:
            raise LifecycleWindowError("session_mode does not match the protected active session.")

    started_at = _parse_started_at(started_at_value)

    if session_mode == "hml":
        _validate_hml_action(
            action=action,
            phase=phase,
            session_id=session_id,
            started_at=started_at,
            now=now,
            confirmation=confirmation,
            minimum_remaining=timedelta(seconds=minimum_remaining_seconds),
        )
        return
    _validate_prd_action(
        action=action,
        phase=phase,
        session_id=session_id,
        started_at=started_at,
        now=now,
        confirmation=confirmation,
        minimum_remaining=timedelta(seconds=minimum_remaining_seconds),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=("start", "teardown"), required=True)
    parser.add_argument("--phase", choices=("bootstrap", "grants"), default="")
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--session-mode", choices=("hml", "prd-window"), required=True)
    parser.add_argument("--lifecycle-dispatch-id", default="")
    parser.add_argument("--confirmation", default="")
    parser.add_argument("--minimum-remaining-seconds", type=int, default=0)
    args = parser.parse_args()

    try:
        validate_database_action(
            dict(os.environ),
            action=args.action,
            phase=args.phase,
            session_id=args.session_id,
            started_at_value=args.started_at,
            session_mode=args.session_mode,
            lifecycle_dispatch_id=args.lifecycle_dispatch_id,
            confirmation=args.confirmation,
            minimum_remaining_seconds=args.minimum_remaining_seconds,
            now=datetime.now(timezone.utc),
        )
    except LifecycleWindowError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print(f"Database {args.session_mode} {args.action} window and protected session accepted.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
