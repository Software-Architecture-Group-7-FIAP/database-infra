import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import ssl
import sys
import urllib.request
from pathlib import Path

WORK = Path("/work")
BOOTSTRAP = Path("/bootstrap")
PASSWORD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
PASSWORD_PATTERN = re.compile(r"^[A-Za-z0-9]{32}$")
HOST_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]*\.us-east-1\.rds\.amazonaws\.com$")
RDS_CA_URL = "https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem"
class MaterializationError(Exception):
    pass


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise MaterializationError
    return value


def write_private(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(payload)
        output.flush()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def pgpass_escape(value: str) -> str:
    if any(character in value for character in ("\x00", "\n", "\r")):
        raise MaterializationError
    return value.replace("\\", "\\\\").replace(":", "\\:")


def scram_verifier(password: str) -> str:
    salt = secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 4096)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    encoded_salt = base64.b64encode(salt).decode("ascii")
    encoded_stored = base64.b64encode(stored_key).decode("ascii")
    encoded_server = base64.b64encode(server_key).decode("ascii")
    return "SCRAM-SHA-256$4096:" + encoded_salt + "$" + encoded_stored + ":" + encoded_server


def parse_secret(env_name: str) -> dict[str, object] | None:
    value = os.environ.get(env_name)
    if value is None:
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        raise MaterializationError from None
    if not isinstance(parsed, dict):
        raise MaterializationError
    return parsed


def download_ca_bundle() -> None:
    context = ssl.create_default_context()
    request = urllib.request.Request(RDS_CA_URL, headers={"User-Agent": "auto-shop-db-bootstrap/1"})
    with urllib.request.urlopen(request, timeout=20, context=context) as response:
        if response.status != 200:
            raise MaterializationError
        bundle = response.read(1_048_577)
    if len(bundle) > 1_048_576 or b"-----BEGIN CERTIFICATE-----" not in bundle or b"-----END CERTIFICATE-----" not in bundle:
        raise MaterializationError
    write_private(WORK / "rds-ca-bundle.pem", bundle)


def expected_payload(username: str, password: str, host: str, port: str, dbname: str) -> dict[str, str]:
    url = f"postgresql://{username}:{password}@{host}:{port}/{dbname}?sslmode=verify-full"
    return {
        "username": username, "password": password, "host": host, "port": port,
        "dbname": dbname, "sslmode": "verify-full", "DATABASE_URL": url,
    }


def pgpass_line(host: str, port: str, dbname: str, username: str, password: str) -> str:
    return ":".join(pgpass_escape(field) for field in (host, port, dbname, username, password))


def write_sql_files(phase: str, environment: str, dbname: str, passwords: dict[str, str]) -> None:
    app_role = f"app_runtime_{environment}"
    lambda_role = f"lambda_auth_{environment}"
    migration_role = f"autoshop_migrations_{environment}"
    if phase == "bootstrap":
        app_password_hash = scram_verifier(passwords[f"runtime-{environment}"])
        lambda_password_hash = scram_verifier(passwords[f"lambda-{environment}"])
        migration_password_hash = scram_verifier(passwords[f"migrations-{environment}"])
        preamble = (
            f"\\set dbname {dbname}\n"
            "\\set owner_role autoshop_owner\n"
            f"\\set app_role {app_role}\n"
            f"\\set lambda_role {lambda_role}\n"
            f"\\set migration_role {migration_role}\n"
            f"\\set app_password_hash {app_password_hash}\n"
            f"\\set lambda_password_hash {lambda_password_hash}\n"
            f"\\set migration_password_hash {migration_password_hash}\n"
        )
        source = (BOOTSTRAP / "00-bootstrap.sql").read_text(encoding="utf-8")
        write_private(WORK / f"bootstrap-{environment}.sql", (preamble + source).encode("utf-8"))
        defaults_preamble = (
            f"\\set dbname {dbname}\n"
            f"\\set app_role {app_role}\n"
            f"\\set migration_role {migration_role}\n"
        )
        defaults_source = (BOOTSTRAP / "05-migration-default-privileges.sql").read_text(encoding="utf-8")
        write_private(
            WORK / f"migration-defaults-{environment}.sql",
            (defaults_preamble + defaults_source).encode("utf-8"),
        )
    elif phase == "grants":
        preamble = (
            f"\\set dbname {dbname}\n"
            f"\\set app_role {app_role}\n"
            f"\\set lambda_role {lambda_role}\n"
            f"\\set migration_role {migration_role}\n"
        )
        source = (BOOTSTRAP / "10-lambda-grants.sql").read_text(encoding="utf-8")
        write_private(WORK / f"grants-{environment}.sql", (preamble + source).encode("utf-8"))


def main() -> None:
    phase = required_env("PHASE")
    environment = required_env("ENVIRONMENT")
    dbname = required_env("DB_NAME")
    if phase not in {"bootstrap", "grants", "smoke"}:
        raise MaterializationError
    if environment not in {"hml", "prd"} or dbname != f"autoshop_{environment}":
        raise MaterializationError
    host = required_env("DB_HOST")
    port = required_env("DB_PORT")
    if not HOST_PATTERN.fullmatch(host) or port != "5432":
        raise MaterializationError
    pass_entries: list[str] = []
    app_passwords: dict[str, str] = {}
    if phase == "bootstrap":
        master = parse_secret("MASTER_SECRET_JSON")
        if master is None or master.get("username") != "autoshop_owner":
            raise MaterializationError
        owner_password = master.get("password")
        if not isinstance(owner_password, str):
            raise MaterializationError
        pass_entries.append(pgpass_line(host, port, "*", "autoshop_owner", owner_password))

    if phase in {"bootstrap", "smoke"}:
        selected_secrets = {
            f"runtime-{environment}": ("RUNTIME_SECRET_JSON", f"app_runtime_{environment}"),
            f"lambda-{environment}": ("LAMBDA_SECRET_JSON", f"lambda_auth_{environment}"),
            f"migrations-{environment}": ("MIGRATIONS_SECRET_JSON", f"autoshop_migrations_{environment}"),
        }
        for key, (secret_env, username) in selected_secrets.items():
            secret = parse_secret(secret_env)
            if secret is None:
                if phase == "smoke":
                    raise MaterializationError
                password = "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(32))
            else:
                if secret.get("username") != username:
                    raise MaterializationError
                password = secret.get("password")
                if not isinstance(password, str) or not PASSWORD_PATTERN.fullmatch(password):
                    raise MaterializationError
            payload = expected_payload(username, password, host, port, dbname)
            if phase == "bootstrap" and (secret is None or secret != payload):
                write_private(WORK / f"payload-{key}.json", json_bytes(payload))
            app_passwords[key] = password
            pass_entries.append(pgpass_line(host, port, "*", username, password))

    if phase == "grants":
        username = f"autoshop_migrations_{environment}"
        secret = parse_secret("MIGRATIONS_SECRET_JSON")
        if secret is None or secret.get("username") != username:
            raise MaterializationError
        password = secret.get("password")
        if not isinstance(password, str) or not PASSWORD_PATTERN.fullmatch(password):
            raise MaterializationError
        pass_entries.append(pgpass_line(host, port, "*", username, password))

    write_private(WORK / "pgpass", ("\n".join(pass_entries) + "\n").encode("utf-8"))
    if phase in {"bootstrap", "grants"}:
        write_sql_files(phase, environment, dbname, app_passwords)
    download_ca_bundle()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("bootstrap input materialization failed", file=sys.stderr)
        raise SystemExit(1)
