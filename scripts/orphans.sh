#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ssm-get-parameters.sh
source "$script_dir/ssm-get-parameters.sh"

usage() {
  printf 'usage: orphans.sh <private-terraform-output-json>\n'
  printf '  ORPHAN_SECRET_DELETE_MAX_ATTEMPTS: 1-60 metadata polls (default 30)\n'
  printf '  ORPHAN_SECRET_DELETE_INTERVAL_SECONDS: 0-10 seconds between polls (default 2)\n'
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 64
fi

manifest="$1"
[[ -r "$manifest" ]] || { printf 'FAIL: Terraform metadata manifest is not readable\n' >&2; exit 1; }

aws_bin="${AWS_BIN:-aws}"
jq_bin="${JQ_BIN:-jq}"
region="${AWS_REGION:-us-east-1}"
command -v "$aws_bin" >/dev/null 2>&1 || [[ -x "$aws_bin" ]] || { printf 'FAIL: aws CLI is required\n' >&2; exit 1; }
command -v "$jq_bin" >/dev/null 2>&1 || [[ -x "$jq_bin" ]] || { printf 'FAIL: jq is required\n' >&2; exit 1; }

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/database-orphans.XXXXXX")"
chmod 700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

secret_poll_max_attempts="${ORPHAN_SECRET_DELETE_MAX_ATTEMPTS:-30}"
secret_poll_interval_seconds="${ORPHAN_SECRET_DELETE_INTERVAL_SECONDS:-2}"
[[ "$secret_poll_max_attempts" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || fail 'secret deletion poll attempt limit must be between 1 and 60'
[[ "$secret_poll_interval_seconds" =~ ^(0|[1-9]|10)$ ]] || fail 'secret deletion poll interval must be between 0 and 10 seconds'

"$jq_bin" -e 'type == "object" and ((tostring | test("postgres(ql)?://|password[[:space:]_]*[:=]|database_url|connection_string|dsn[[:space:]_]*[:=]"; "i")) | not)' "$manifest" >/dev/null \
  || fail 'Terraform metadata manifest is invalid or contains a prohibited connection value'

manifest_value() {
  # shellcheck disable=SC2016
  "$jq_bin" -r --arg key "$1" '.[$key].value // .[$key] // empty' "$manifest"
}

aws_json() {
  local label="$1"
  shift
  if ! "$aws_bin" --region "$region" "$@" --output json > "$tmp_dir/$label.json" 2> "$tmp_dir/$label.stderr"; then
    fail "$label metadata query failed"
  fi
}

assert_no_items() {
  local label="$1"
  local expression="$2"
  local filename="$3"
  if ! "$jq_bin" -e "$expression" "$tmp_dir/$filename.json" >/dev/null 2>&1; then
    fail "orphan detected or ownership query incomplete: $label"
  fi
  pass "$label absent"
}

assert_named_resource_absent() {
  local label="$1"
  shift
  local filename="$1"
  shift
  if "$aws_bin" --region "$region" "$@" --output json > "$tmp_dir/$filename.json" 2> "$tmp_dir/$filename.stderr"; then
    fail "orphan detected: $label"
  fi
  if ! grep -Eq 'ResourceNotFound|NotFound|NoSuchEntity|InvalidGroup\.NotFound|DBInstanceNotFound' "$tmp_dir/$filename.stderr"; then
    fail "$label query failed for a reason other than not found"
  fi
  pass "$label absent"
}

assert_secret_absent_or_pending() {
  local label="$1"
  local secret_id="$2"
  local filename="$3"
  local attempt
  local deleted_date

  for ((attempt = 1; attempt <= secret_poll_max_attempts; attempt++)); do
    if "$aws_bin" --region "$region" secretsmanager describe-secret \
      --secret-id "$secret_id" --query 'DeletedDate' --output text \
      > "$tmp_dir/$filename.deleted-date" 2> "$tmp_dir/$filename.stderr"; then
      deleted_date="$(<"$tmp_dir/$filename.deleted-date")"
      if [[ -z "$deleted_date" || "$deleted_date" == "None" || "$deleted_date" == "null" ]]; then
        fail "orphan detected: $label"
      fi

      if (( attempt < secret_poll_max_attempts )); then
        sleep "$secret_poll_interval_seconds"
        continue
      fi

      fail "$label remained pending deletion after bounded metadata polling"
    fi

    if grep -Eq 'ResourceNotFound|NotFound' "$tmp_dir/$filename.stderr"; then
      pass "$label absent"
      return
    fi

    fail "$label metadata query failed for a reason other than not found"
  done
}

aws_json tagged_resources resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=auto-shop Key=Repository,Values=database-infra
assert_no_items 'all tagged database-infra resources' \
  '(.ResourceTagMappingList | length == 0)' tagged_resources

assert_named_resource_absent 'staging RDS instance' rds_instance rds describe-db-instances --db-instance-identifier auto-shop-staging

aws_json manual_snapshots rds describe-db-snapshots --db-instance-identifier auto-shop-staging --snapshot-type manual
assert_no_items 'manual RDS snapshots' '(.DBSnapshots | length == 0)' manual_snapshots

aws_json automated_snapshots rds describe-db-snapshots --db-instance-identifier auto-shop-staging --snapshot-type automated
assert_no_items 'automated RDS snapshots' '(.DBSnapshots | length == 0)' automated_snapshots

aws_json automated_backups rds describe-db-instance-automated-backups --db-instance-identifier auto-shop-staging
assert_no_items 'automated RDS backups' '(.DBInstanceAutomatedBackups | length == 0)' automated_backups

assert_named_resource_absent 'RDS subnet group' subnet_group rds describe-db-subnet-groups --db-subnet-group-name auto-shop-staging-db
assert_named_resource_absent 'RDS parameter group' parameter_group rds describe-db-parameter-groups --db-parameter-group-name auto-shop-staging-postgres16

security_group_id="$(manifest_value db_security_group_id)"
if [[ -n "$security_group_id" ]]; then
  assert_named_resource_absent 'RDS security group' security_group ec2 describe-security-groups --group-ids "$security_group_id"
fi

for secret_name in \
  auto-shop/staging/hml/app-runtime \
  auto-shop/staging/prd/app-runtime \
  auto-shop/staging/hml/lambda-auth \
  auto-shop/staging/prd/lambda-auth; do
  safe_name="$(printf '%s' "$secret_name" | tr '/-' '__')"
  assert_secret_absent_or_pending "Secrets Manager metadata $secret_name" "$secret_name" "secret-$safe_name"
done

owner_secret_arn="$(manifest_value owner_secret_arn)"
if [[ -n "$owner_secret_arn" ]]; then
  assert_secret_absent_or_pending 'RDS-managed master secret metadata' "$owner_secret_arn" owner_secret
fi

assert_named_resource_absent 'bootstrap IAM role' bootstrap_role iam get-role --role-name auto-shop-staging-db-bootstrap
for policy_name in \
  auto-shop-staging-db-read-owner \
  auto-shop-staging-db-read-lambda-hml \
  auto-shop-staging-db-read-lambda-prd; do
  policy_arn="arn:aws:iam::035611741563:policy/auto-shop/$policy_name"
  safe_name="$(printf '%s' "$policy_name" | tr '-' '_')"
  assert_named_resource_absent "managed IAM policy $policy_name" "policy-$safe_name" iam get-policy --policy-arn "$policy_arn"
done

cluster_json="$tmp_dir/cluster.json"
if ! "$aws_bin" --region "$region" ssm get-parameter --name /auto-shop/staging/eks/cluster-name --output json > "$cluster_json" 2> "$tmp_dir/cluster.stderr"; then
  fail 'the upstream EKS cluster-name contract could not be read; Pod Identity cleanup is unverifiable'
fi
cluster_name="$("$jq_bin" -r '.Parameter.Value // empty' "$cluster_json")"
[[ -n "$cluster_name" ]] || fail 'the upstream EKS cluster-name contract is empty'
if ! "$aws_bin" --region "$region" eks describe-cluster --name "$cluster_name" --output json > "$tmp_dir/cluster-description.json" 2> "$tmp_dir/cluster-description.stderr"; then
  fail 'the EKS cluster is unavailable; Pod Identity association cleanup needs operator review'
fi
aws_json pod_identity eks list-pod-identity-associations \
  --cluster-name "$cluster_name" --namespace auto-shop-ops --service-account auto-shop-db-bootstrap
assert_no_items 'bootstrap Pod Identity association' '(.associations | length == 0)' pod_identity

output_parameter_names=(
  /auto-shop/staging/database/host
  /auto-shop/staging/database/port
  /auto-shop/staging/database/security-group-id
  /auto-shop/staging/database/names/hml
  /auto-shop/staging/database/names/prd
  /auto-shop/staging/database/secrets/runtime-hml-arn
  /auto-shop/staging/database/secrets/runtime-prd-arn
  /auto-shop/staging/database/secrets/lambda-hml-arn
  /auto-shop/staging/database/secrets/lambda-prd-arn
  /auto-shop/staging/database/secrets/owner-arn
  /auto-shop/staging/database/iam/owner-read-policy-arn
  /auto-shop/staging/database/iam/lambda-read-policy-arn/hml
  /auto-shop/staging/database/iam/lambda-read-policy-arn/prd
)
if ! capture_ssm_get_parameters_batched \
  "$tmp_dir/output_parameters.json" "$aws_bin" "$region" "$jq_bin" "$tmp_dir" \
  "${output_parameter_names[@]}"; then
  fail 'published database SSM parameter metadata query failed'
fi
assert_no_items 'published database SSM parameters' '(.Parameters | length == 0)' output_parameters

pass 'database-infra orphan scan completed without querying secret values or broad SSM paths'
