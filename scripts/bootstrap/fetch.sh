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
[[ "${ENVIRONMENT:-}" == hml || "${ENVIRONMENT:-}" == prd ]] || fail
expected_role_arn="arn:aws:iam::035611741563:role/auto-shop/auto-shop-staging-db-bootstrap-$ENVIRONMENT"
[[ "${BOOTSTRAP_ROLE_ARN:-}" == "$expected_role_arn" ]] || fail
if ! aws configure export-credentials --format process > /work/aws-credentials.json 2> /work/aws-credentials.stderr; then fail; fi
chmod 600 /work/aws-credentials.json
if ! jq -e '(.AccessKeyId | type == "string" and length > 0) and (.SecretAccessKey | type == "string" and length > 0) and (.SessionToken | type == "string" and length > 0)' /work/aws-credentials.json >/dev/null 2>&1; then fail; fi
if ! aws sts get-caller-identity --query Arn --output text > /work/caller-arn.txt 2> /work/caller-arn.stderr; then fail; fi
expected_caller_prefix="arn:aws:sts::035611741563:assumed-role/auto-shop-staging-db-bootstrap-$ENVIRONMENT/"
caller_arn="$(cat /work/caller-arn.txt)"
[[ "$caller_arn" == "$expected_caller_prefix"* && "${caller_arn#"$expected_caller_prefix"}" =~ ^[A-Za-z0-9+=,.@_-]+$ ]] || fail
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
  record_secret_state "runtime-$ENVIRONMENT" "$RUNTIME_SECRET_ARN"
  record_secret_state "lambda-$ENVIRONMENT" "$LAMBDA_SECRET_ARN"
  record_secret_state "migrations-$ENVIRONMENT" "$MIGRATIONS_SECRET_ARN"
fi
rm -f /work/aws-credentials.stderr /work/caller-arn.stderr /work/meta-*.stderr
