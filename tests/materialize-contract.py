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


def main() -> None:
    dbnames = {"hml": "autoshop_hml", "prd": "autoshop_prd"}
    passwords = {
        "runtime-hml": "local-hml-runtime-only",
        "lambda-hml": "local-hml-lambda-only",
        "runtime-prd": "local-prd-runtime-only",
        "lambda-prd": "local-prd-lambda-only",
        "migrations-hml": "local-hml-migrations-only",
        "migrations-prd": "local-prd-migrations-only",
    }
    with tempfile.TemporaryDirectory(prefix="materialize-contract-") as directory:
        MATERIALIZE.WORK = Path(directory)
        MATERIALIZE.BOOTSTRAP = REPO_ROOT / "sql"
        MATERIALIZE.write_sql_files("bootstrap", dbnames, passwords)
        for environment in ("hml", "prd"):
            sql_file = MATERIALIZE.WORK / f"bootstrap-{environment}.sql"
            lines = check_private(sql_file)
            role = f"app_runtime_{environment}"
            lambda_role = f"lambda_auth_{environment}"
            migration_role = f"autoshop_migrations_{environment}"
            expected = [
                rf"\set dbname autoshop_{environment}",
                r"\set owner_role autoshop_owner",
                rf"\set app_role {role}",
                rf"\set lambda_role {lambda_role}",
                rf"\set migration_role {migration_role}",
            ]
            require(lines[:5] == expected, "bootstrap psql preamble must use one command slash and unquoted validated values")
            require(lines[5].startswith(r"\set app_password_hash SCRAM-SHA-256$4096:"), "runtime SCRAM verifier is not a psql value")
            require(lines[6].startswith(r"\set lambda_password_hash SCRAM-SHA-256$4096:"), "Lambda SCRAM verifier is not a psql value")
            require(lines[7].startswith(r"\set migration_password_hash SCRAM-SHA-256$4096:"), "migration SCRAM verifier is not a psql value")
            hash_pattern = re.compile(r"^SCRAM-SHA-256" + re.escape(chr(36)) + r"4096:[A-Za-z0-9+/]{22}==" + re.escape(chr(36)) + r"[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=\Z")
            require(all(hash_pattern.fullmatch(lines[index].split(maxsplit=2)[2]) is not None for index in (5, 6, 7)), "SCRAM verifier has invalid base64 padding or length")
            require(all(line.count("'") == 0 for line in lines[:8]), "bootstrap psql preamble must not include quote characters")

            defaults_file = MATERIALIZE.WORK / f"migration-defaults-{environment}.sql"
            defaults_lines = check_private(defaults_file)
            defaults_expected = [
                rf"\set dbname autoshop_{environment}",
                rf"\set app_role app_runtime_{environment}",
                rf"\set migration_role autoshop_migrations_{environment}",
            ]
            require(defaults_lines[:3] == defaults_expected, "migration default privilege psql preamble must match the environment roles")

        MATERIALIZE.write_sql_files("grants", dbnames, {})
        for environment in ("hml", "prd"):
            sql_file = MATERIALIZE.WORK / f"grants-{environment}.sql"
            lines = check_private(sql_file)
            expected = [
                rf"\set dbname autoshop_{environment}",
                rf"\set app_role app_runtime_{environment}",
                rf"\set lambda_role lambda_auth_{environment}",
                rf"\set migration_role autoshop_migrations_{environment}",
            ]
            require(lines[:4] == expected, "grants psql preamble must use one command slash and unquoted validated values")

    print("PASS: materialize emits private PostgreSQL 16 psql inputs with safe single-slash variables")


if __name__ == "__main__":
    main()
