#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "hml" && "$1" != "prd" ) ]]; then
  printf 'usage: orphans-environment.sh <hml|prd>\n' >&2
  exit 64
fi

environment="$1"
aws_bin="${AWS_BIN:-aws}"
jq_bin="${JQ_BIN:-jq}"
region="${AWS_REGION:-us-east-1}"
command -v "$aws_bin" >/dev/null 2>&1 || { printf 'FAIL: aws CLI is required\n' >&2; exit 1; }
command -v "$jq_bin" >/dev/null 2>&1 || { printf 'FAIL: jq is required\n' >&2; exit 1; }

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/database-environment-orphans.XXXXXX")"
chmod 700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

policy_names=(
  "auto-shop-staging-db-read-lambda-$environment"
  "auto-shop-staging-db-read-migrations-$environment"
  "auto-shop-staging-db-bootstrap-$environment-secrets"
)
policy_arns=()
for policy_name in "${policy_names[@]}"; do
  policy_arn="arn:aws:iam::035611741563:policy/auto-shop/$policy_name"
  policy_arns+=("$policy_arn")
  if "$aws_bin" iam get-policy --policy-arn "$policy_arn" > "$tmp_dir/policy.json" 2> "$tmp_dir/policy.stderr"; then
    fail "environment IAM policy remains: $policy_name"
  fi
  grep -q 'NoSuchEntity' "$tmp_dir/policy.stderr" || fail "IAM policy query failed: $policy_name"
done

bootstrap_role="auto-shop-staging-db-bootstrap-$environment"
if "$aws_bin" iam get-role --role-name "$bootstrap_role" > "$tmp_dir/role.json" 2> "$tmp_dir/role.stderr"; then
  fail "environment bootstrap IAM role remains: $bootstrap_role"
fi
grep -q 'NoSuchEntity' "$tmp_dir/role.stderr" || fail "bootstrap IAM role query failed: $bootstrap_role"

if ! "$aws_bin" iam list-attached-role-policies --role-name auto-shop-staging-db-bootstrap \
  > "$tmp_dir/attachments.json" 2> "$tmp_dir/attachments.stderr"; then
  fail 'shared bootstrap role attachments could not be checked'
fi
for policy_arn in "${policy_arns[@]}"; do
  if "$jq_bin" -e --arg policy_arn "$policy_arn" \
    'any(.AttachedPolicies[]?; .PolicyArn == $policy_arn)' "$tmp_dir/attachments.json" >/dev/null; then
    fail "environment policy is still attached to the shared bootstrap role: $policy_arn"
  fi
done

secret_names=(
  "auto-shop/staging/$environment/app-runtime"
  "auto-shop/staging/$environment/lambda-auth"
  "auto-shop/staging/$environment/migrations"
)
for secret_name in "${secret_names[@]}"; do
  if "$aws_bin" --region "$region" secretsmanager describe-secret \
    --secret-id "$secret_name" --query DeletedDate --output text \
    > "$tmp_dir/secret.deleted-date" 2> "$tmp_dir/secret.stderr"; then
    deleted_date="$(<"$tmp_dir/secret.deleted-date")"
    [[ -n "$deleted_date" && "$deleted_date" != "None" && "$deleted_date" != "null" ]] \
      || fail "active environment secret metadata remains: $secret_name"
  elif ! grep -Eq 'ResourceNotFound|ResourceNotFoundException' "$tmp_dir/secret.stderr"; then
    fail "secret metadata query failed: $secret_name"
  fi
done

ssm_names=(
  "/auto-shop/staging/database/names/$environment"
  "/auto-shop/staging/database/secrets/runtime-$environment-arn"
  "/auto-shop/staging/database/secrets/lambda-$environment-arn"
  "/auto-shop/staging/database/secrets/migrations-$environment-arn"
  "/auto-shop/staging/database/iam/migrations-$environment-read-policy-arn"
  "/auto-shop/staging/database/iam/lambda-read-policy-arn/$environment"
  "/auto-shop/staging/database/iam/bootstrap-role-arn/$environment"
)
if ! "$aws_bin" --region "$region" ssm get-parameters --names "${ssm_names[@]}" \
  --output json > "$tmp_dir/parameters.json" 2> "$tmp_dir/parameters.stderr"; then
  fail 'environment SSM metadata query failed'
fi
if ! "$jq_bin" -e --argjson expected "${#ssm_names[@]}" \
  '(.Parameters | length == 0) and (.InvalidParameters | length == $expected)' \
  "$tmp_dir/parameters.json" >/dev/null; then
  fail "one or more $environment SSM contract parameters remain"
fi

if ! "$aws_bin" --region "$region" rds describe-db-instances \
  --db-instance-identifier auto-shop-staging --query 'DBInstances[0].DBInstanceStatus' \
  --output text > "$tmp_dir/shared-rds-status.txt" 2> "$tmp_dir/shared-rds.stderr"; then
  fail 'shared staging RDS could not be verified after environment teardown'
fi
[[ "$(<"$tmp_dir/shared-rds-status.txt")" == "available" ]] \
  || fail 'shared staging RDS is not available after environment teardown'

if "$aws_bin" --region "$region" ssm get-parameter --name /auto-shop/staging/eks/cluster-name \
  --query Parameter.Value --output text > "$tmp_dir/cluster-name.txt" 2> "$tmp_dir/cluster-name.stderr"; then
  cluster_name="$(<"$tmp_dir/cluster-name.txt")"
  service_account="auto-shop-db-bootstrap-$environment"
  if ! "$aws_bin" --region "$region" eks list-pod-identity-associations \
    --cluster-name "$cluster_name" \
    --namespace auto-shop-ops \
    --service-account "$service_account" \
    --output json > "$tmp_dir/pod-identity.json" 2> "$tmp_dir/pod-identity.stderr"; then
    fail 'environment Pod Identity association could not be checked after teardown'
  fi
  if ! "$jq_bin" -e '(.associations | type == "array") and (.associations | length == 0)' \
    "$tmp_dir/pod-identity.json" >/dev/null; then
    fail "environment Pod Identity association remains for $service_account"
  fi
elif ! grep -Eq 'ParameterNotFound|ParameterNotFoundException' "$tmp_dir/cluster-name.stderr"; then
  fail 'EKS cluster-name metadata could not be checked after environment teardown'
fi

printf 'PASS: %s-owned roles, secrets, policies, SSM parameters, and Pod Identity associations are absent; the shared RDS remains available\n' "$environment"
