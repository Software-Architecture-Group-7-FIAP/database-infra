import json
import os
import subprocess
import sys
from pathlib import Path

WORK = Path("/work")
ASM_EXEC = Path("/bootstrap/asm-exec")
MATERIALIZE = Path("/bootstrap/materialize.py")
SECRET_TYPES = {
    "runtime": ("RUNTIME_SECRET_ARN", "RUNTIME_SECRET_JSON"),
    "lambda": ("LAMBDA_SECRET_ARN", "LAMBDA_SECRET_JSON"),
    "migrations": ("MIGRATIONS_SECRET_ARN", "MIGRATIONS_SECRET_JSON"),
}


def fail() -> None:
    print("bootstrap secret resolution or materialization failed", file=sys.stderr)
    raise SystemExit(1)


def reference(secret_arn: str) -> str:
    return "{{resolve:secretsmanager:" + secret_arn + ":SecretString}}"


def main() -> None:
    try:
        credentials = json.loads((WORK / "aws-credentials.json").read_text(encoding="utf-8"))
        state = json.loads((WORK / "secret-state.json").read_text(encoding="utf-8"))
        if not isinstance(credentials, dict) or not isinstance(state, dict):
            fail()
        access_key = credentials.get("AccessKeyId")
        secret_key = credentials.get("SecretAccessKey")
        session_token = credentials.get("SessionToken")
        if not all(isinstance(value, str) and value for value in (access_key, secret_key, session_token)):
            fail()
        phase = os.environ.get("PHASE", "")
        environment = os.environ.get("ENVIRONMENT", "")
        if environment not in {"hml", "prd"}:
            fail()
        if phase not in {"bootstrap", "grants", "smoke"}:
            fail()
        child_env = os.environ.copy()
        child_env.update({
            "AWS_ACCESS_KEY_ID": access_key,
            "AWS_SECRET_ACCESS_KEY": secret_key,
            "AWS_SESSION_TOKEN": session_token,
            "AWS_DEFAULT_REGION": os.environ["AWS_REGION"],
            "ENVIRONMENT": environment,
            "TMPDIR": "/work/tmp",
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        if phase == "bootstrap":
            child_env["MASTER_SECRET_JSON"] = reference(os.environ["OWNER_SECRET_ARN"])
        child_env["DB_NAME"] = os.environ["DB_NAME"]
        selected_secret_types = {
            "bootstrap": tuple(SECRET_TYPES),
            "smoke": tuple(SECRET_TYPES),
            "grants": ("migrations",),
        }[phase]
        for secret_type in selected_secret_types:
            arn_key, secret_key_name = SECRET_TYPES[secret_type]
            if phase == "bootstrap":
                state_key = f"{secret_type}-{environment}"
                current = state.get(state_key)
                if not isinstance(current, bool):
                    fail()
                if not current:
                    continue
            child_env[secret_key_name] = reference(os.environ[arn_key])
        with (WORK / "asm-exec.stdout").open("wb") as stdout_file, (WORK / "asm-exec.stderr").open("wb") as stderr_file:
            result = subprocess.run(
                [sys.executable, str(ASM_EXEC), "--", sys.executable, str(MATERIALIZE)],
                env=child_env, stdout=stdout_file, stderr=stderr_file, check=False, timeout=300,
            )
        if result.returncode != 0:
            fail()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        fail()


if __name__ == "__main__":
    main()
