#!/usr/bin/env python3
import importlib.util
import re
import stat
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE = REPO_ROOT / "scripts" / "bootstrap" / "materialize.py"
SPEC = importlib.util.spec_from_file_location("bootstrap_materialize", SOURCE)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("FAIL: materialize.py could not be imported")
MATERIALIZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATERIALIZE)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def check_private(path: Path) -> list[str]:
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, f"{path.name} is not mode 0600")
    return path.read_text(encoding="utf-8").splitlines()


def check_environment(environment: str) -> None:
    dbname = f"autoshop_{environment}"
    passwords = {
        f"runtime-{environment}": f"local-{environment}-runtime-only",
        f"lambda-{environment}": f"local-{environment}-lambda-only",
        f"migrations-{environment}": f"local-{environment}-migrations-only",
    }
    other_environment = "prd" if environment == "hml" else "hml"
    with tempfile.TemporaryDirectory(prefix="materialize-contract-") as directory:
        MATERIALIZE.WORK = Path(directory)
        MATERIALIZE.BOOTSTRAP = REPO_ROOT / "sql"
        MATERIALIZE.write_sql_files("bootstrap", environment, dbname, passwords)
        sql_file = MATERIALIZE.WORK / f"bootstrap-{environment}.sql"
        lines = check_private(sql_file)
        expected = [
            rf"\set dbname {dbname}",
            r"\set owner_role autoshop_owner",
            rf"\set app_role app_runtime_{environment}",
            rf"\set lambda_role lambda_auth_{environment}",
            rf"\set migration_role autoshop_migrations_{environment}",
        ]
        require(lines[:5] == expected, "bootstrap psql preamble must use only selected-environment roles")
        require(lines[5].startswith(r"\set app_password_hash SCRAM-SHA-256$4096:"), "runtime SCRAM verifier is not a psql value")
        require(lines[6].startswith(r"\set lambda_password_hash SCRAM-SHA-256$4096:"), "Lambda SCRAM verifier is not a psql value")
        require(lines[7].startswith(r"\set migration_password_hash SCRAM-SHA-256$4096:"), "migration SCRAM verifier is not a psql value")
        hash_pattern = re.compile(r"^SCRAM-SHA-256" + re.escape(chr(36)) + r"4096:[A-Za-z0-9+/]{22}==" + re.escape(chr(36)) + r"[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=\Z")
        require(all(hash_pattern.fullmatch(lines[index].split(maxsplit=2)[2]) is not None for index in (5, 6, 7)), "SCRAM verifier has invalid base64 padding or length")
        require(all(line.count("'") == 0 for line in lines[:8]), "bootstrap psql preamble must not include quote characters")

        defaults = check_private(MATERIALIZE.WORK / f"migration-defaults-{environment}.sql")
        require(defaults[:3] == [
            rf"\set dbname {dbname}",
            rf"\set app_role app_runtime_{environment}",
            rf"\set migration_role autoshop_migrations_{environment}",
        ], "migration default-privilege inputs must use selected-environment roles")

        MATERIALIZE.write_sql_files("grants", environment, dbname, {})
        grants = check_private(MATERIALIZE.WORK / f"grants-{environment}.sql")
        require(grants[:4] == [
            rf"\set dbname {dbname}",
            rf"\set app_role app_runtime_{environment}",
            rf"\set lambda_role lambda_auth_{environment}",
            rf"\set migration_role autoshop_migrations_{environment}",
        ], "grants psql inputs must use selected-environment roles")
        require(not (MATERIALIZE.WORK / f"bootstrap-{other_environment}.sql").exists(), "bootstrap generated SQL for the other environment")
        require(not (MATERIALIZE.WORK / f"grants-{other_environment}.sql").exists(), "grants generated SQL for the other environment")


def main() -> None:
    for environment in ("hml", "prd"):
        check_environment(environment)
    print("PASS: materialize emits private PostgreSQL inputs scoped to exactly one environment")


if __name__ == "__main__":
    main()
