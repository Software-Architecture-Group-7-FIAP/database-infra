import json
import os
import subprocess
import sys
from pathlib import Path

WORK = Path("/work")
ASM_EXEC = Path("/bootstrap/asm-exec")
MATERIALIZE = Path("/bootstrap/materialize.py")
SECRET_ENVIRONMENTS = {
    "runtime-hml": ("RUNTIME_HML_SECRET_ARN", "RUNTIME_HML_SECRET_JSON"),
    "runtime-prd": ("RUNTIME_PRD_SECRET_ARN", "RUNTIME_PRD_SECRET_JSON"),
    "lambda-hml": ("LAMBDA_HML_SECRET_ARN", "LAMBDA_HML_SECRET_JSON"),
    "lambda-prd": ("LAMBDA_PRD_SECRET_ARN", "LAMBDA_PRD_SECRET_JSON"),
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
        if phase not in {"bootstrap", "grants", "smoke"}:
            fail()
        child_env = os.environ.copy()
        child_env.update({
            "AWS_ACCESS_KEY_ID": access_key,
            "AWS_SECRET_ACCESS_KEY": secret_key,
            "AWS_SESSION_TOKEN": session_token,
            "AWS_DEFAULT_REGION": os.environ["AWS_REGION"],
            "TMPDIR": "/work/tmp",
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        if phase in {"bootstrap", "grants"}:
            child_env["MASTER_SECRET_JSON"] = reference(os.environ["OWNER_SECRET_ARN"])
        if phase == "bootstrap":
            for state_key, (arn_key, secret_key_name) in SECRET_ENVIRONMENTS.items():
                current = state.get(state_key)
                if not isinstance(current, bool):
                    fail()
                if current:
                    child_env[secret_key_name] = reference(os.environ[arn_key])
        elif phase == "smoke":
            for arn_key, secret_key_name in SECRET_ENVIRONMENTS.values():
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
