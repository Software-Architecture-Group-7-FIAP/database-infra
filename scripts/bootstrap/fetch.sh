#!/usr/bin/env bash
set -euo pipefail
umask 077
export HOME=/work/home
export TMPDIR=/work/tmp
export AWS_CONFIG_FILE=/work/home/.aws/config
export AWS_SHARED_CREDENTIALS_FILE=/work/home/.aws/credentials
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
mkdir -p /work/home/.aws /work/tmp
fail() { printf 'bootstrap credential metadata preparation failed\n' >&2; exit 1; }
if ! aws configure export-credentials --format process > /work/aws-credentials.json 2> /work/aws-credentials.stderr; then fail; fi
chmod 600 /work/aws-credentials.json
if ! jq -e '(.AccessKeyId | type == "string" and length > 0) and (.SecretAccessKey | type == "string" and length > 0) and (.SessionToken | type == "string" and length > 0)' /work/aws-credentials.json >/dev/null 2>&1; then fail; fi
printf '{}\n' > /work/secret-state.json
chmod 600 /work/secret-state.json
record_secret_state() {
  local name="$1" arn="$2" metadata_path="/work/meta-$1.json" stderr_path="/work/meta-$1.stderr" current
  if ! aws --region "$AWS_REGION" secretsmanager describe-secret --secret-id "$arn" --query VersionIdsToStages --output json >"$metadata_path" 2>"$stderr_path"; then fail; fi
  if ! jq -e 'type == "object" or . == null' "$metadata_path" >/dev/null 2>&1; then fail; fi
  current="$(jq -r '(. // {}) | any(to_entries[]; (.value | index("AWSCURRENT")) != null)' "$metadata_path")"
  if ! jq --arg name "$name" --argjson current "$current" '. + {($name): $current}' /work/secret-state.json > /work/secret-state.next.json 2>/dev/null; then fail; fi
  mv /work/secret-state.next.json /work/secret-state.json
  chmod 600 /work/secret-state.json
}
if [[ "$PHASE" == "bootstrap" ]]; then
  record_secret_state runtime-hml "$RUNTIME_HML_SECRET_ARN"
  record_secret_state runtime-prd "$RUNTIME_PRD_SECRET_ARN"
  record_secret_state lambda-hml "$LAMBDA_HML_SECRET_ARN"
  record_secret_state lambda-prd "$LAMBDA_PRD_SECRET_ARN"
  record_secret_state migrations-hml "$MIGRATIONS_HML_SECRET_ARN"
  record_secret_state migrations-prd "$MIGRATIONS_PRD_SECRET_ARN"
fi
rm -f /work/aws-credentials.stderr /work/meta-*.stderr
