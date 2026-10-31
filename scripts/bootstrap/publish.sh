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

fail() {
  printf 'application credential publication failed; private diagnostics were discarded\n' >&2
  exit 1
}
if [[ "$PHASE" != "bootstrap" ]]; then
  exit 0
fi
if [[ "${ENVIRONMENT:-}" != hml && "${ENVIRONMENT:-}" != prd ]]; then
  fail
fi
publish_payload() {
  local key="$1" arn="$2" payload="/work/payload-$1.json"
  [[ -f "$payload" ]] || return 0
  if ! aws --region "$AWS_REGION" secretsmanager put-secret-value \
    --secret-id "$arn" --secret-string "file://$payload" \
    >"/work/publish-$key.stdout" 2>"/work/publish-$key.stderr"; then
    fail
  fi
}
publish_payload "runtime-$ENVIRONMENT" "$RUNTIME_SECRET_ARN"
publish_payload "lambda-$ENVIRONMENT" "$LAMBDA_SECRET_ARN"
publish_payload "migrations-$ENVIRONMENT" "$MIGRATIONS_SECRET_ARN"
