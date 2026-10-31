#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ssm-get-parameters.sh
source "$script_dir/ssm-get-parameters.sh"

phase=initial
if [[ $# -ne 2 || ( "$2" != hml && "$2" != prd ) ]]; then
  printf 'usage: smoke.sh <initial|full> <hml|prd>\n' >&2
  exit 64
fi
phase="$1"
environment="$2"
case "$phase" in
  initial) ;;
  full)
    if ! "$script_dir/bootstrap-db.sh" smoke "$environment"; then
      printf 'FAIL: full in-cluster TLS and permission smoke failed\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'usage: smoke.sh <initial|full> <hml|prd>\n' >&2
    exit 64
    ;;
esac

region="${AWS_REGION:-us-east-1}"
aws_bin="${AWS_BIN:-aws}"
jq_bin="${JQ_BIN:-jq}"
command -v "$aws_bin" >/dev/null 2>&1 || [[ -x "$aws_bin" ]] || { printf 'FAIL: aws CLI is required\n' >&2; exit 1; }
command -v "$jq_bin" >/dev/null 2>&1 || [[ -x "$jq_bin" ]] || { printf 'FAIL: jq is required\n' >&2; exit 1; }

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/database-smoke.XXXXXX")"
chmod 700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

capture_aws_json() {
  local label="$1"
  shift
  if ! "$aws_bin" --region "$region" "$@" --output json > "$tmp_dir/$label.json" 2> "$tmp_dir/$label.stderr"; then
    fail "$label metadata query failed"
  fi
}

assert_json() {
  local label="$1"
  local expression="$2"
  local filename="$3"
  if ! "$jq_bin" -e "$expression" "$tmp_dir/$filename.json" >/dev/null 2>&1; then
    fail "$label invariant failed"
  fi
  pass "$label"
}

required_output_parameters=(
  /auto-shop/staging/database/host
  /auto-shop/staging/database/port
  /auto-shop/staging/database/security-group-id
  "/auto-shop/staging/database/names/$environment"
  "/auto-shop/staging/database/secrets/runtime-$environment-arn"
  "/auto-shop/staging/database/secrets/lambda-$environment-arn"
  "/auto-shop/staging/database/secrets/migrations-$environment-arn"
  "/auto-shop/staging/database/iam/lambda-read-policy-arn/$environment"
  "/auto-shop/staging/database/iam/migrations-$environment-read-policy-arn"
  "/auto-shop/staging/database/iam/bootstrap-role-arn/$environment"
)

if ! capture_ssm_get_parameters_batched \
  "$tmp_dir/parameters.json" "$aws_bin" "$region" "$jq_bin" "$tmp_dir" \
  "${required_output_parameters[@]}"; then
  fail 'SSM parameter metadata query failed'
fi
assert_json 'SSM contract contains exactly the approved plain String parameters' \
  '(.InvalidParameters | length == 0) and (.Parameters | length == 10) and all(.Parameters[]; .Type == "String" and (.Name | startswith("/auto-shop/staging/database/"))) and all(.Parameters[]; (.Value | test("postgres(ql)?://|password[[:space:]_]*[:=]|database_url|connection_string|dsn[[:space:]_]*[:=]"; "i") | not))' \
  parameters

capture_aws_json instance rds describe-db-instances --db-instance-identifier auto-shop-staging
assert_json 'RDS is available, private, encrypted PostgreSQL 16.15 Single-AZ with one-day retention' \
  '(.DBInstances | length == 1) and (.DBInstances[0] | .DBInstanceStatus == "available" and .PubliclyAccessible == false and .MultiAZ == false and .Engine == "postgres" and .EngineVersion == "16.15" and .StorageEncrypted == true and .BackupRetentionPeriod == 1 and .DeletionProtection == false)' \
  instance

capture_aws_json upstream_subnets ssm get-parameter --name /auto-shop/staging/network/rds-isolated-subnet-ids
assert_json 'upstream RDS subnet contract is a StringList' \
  '.Parameter.Type == "StringList" and (.Parameter.Value | split(",") | length >= 2)' \
  upstream_subnets

capture_aws_json subnet_group rds describe-db-subnet-groups --db-subnet-group-name auto-shop-staging-db
# shellcheck disable=SC2016
if ! "$jq_bin" -n -e \
  --slurpfile subnet_group "$tmp_dir/subnet_group.json" \
  --slurpfile upstream_subnets "$tmp_dir/upstream_subnets.json" '
  # LCOV_EXCL_START
  ($subnet_group[0].DBSubnetGroups[0].Subnets | map(.SubnetIdentifier) | sort)
  == ($upstream_subnets[0].Parameter.Value | split(",") | map(gsub("^\\s+|\\s+$"; "")) | sort)
  # LCOV_EXCL_STOP
' >/dev/null 2>&1; then
  fail 'RDS subnet group does not match the upstream isolated subnet list'
fi
pass 'RDS subnet group uses exactly the upstream isolated subnets'

security_group_id="$("$jq_bin" -r '.Parameters[] | select(.Name == "/auto-shop/staging/database/security-group-id") | .Value' "$tmp_dir/parameters.json")"
[[ "$security_group_id" =~ ^sg-[0-9a-f]+$ ]] || fail 'published database security group ID is invalid'
capture_aws_json security_group ec2 describe-security-groups --group-ids "$security_group_id"
# shellcheck disable=SC2016
assert_json 'security group has exactly two SG-referenced TCP 5432 ingress rules and no egress' \
  '(.SecurityGroups | length == 1) and (.SecurityGroups[0].IpPermissions | length == 2) and (.SecurityGroups[0].IpPermissionsEgress | length == 0) and ([.SecurityGroups[0].IpPermissions[] | select(.IpProtocol == "tcp" and .FromPort == 5432 and .ToPort == 5432 and (.UserIdGroupPairs | length == 1) and (.IpRanges | length == 0) and (.Ipv6Ranges | length == 0) and (.PrefixListIds | length == 0))] | length == 2)' \
  security_group

subnet_ids="$("$jq_bin" -r '.Parameter.Value | split(",") | .[] | gsub("^\\s+|\\s+$"; "")' "$tmp_dir/upstream_subnets.json")"
subnet_index=0
while IFS= read -r subnet_id; do
  [[ -n "$subnet_id" ]] || continue
  subnet_index=$((subnet_index + 1))
  capture_aws_json "routes-$subnet_index" ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet_id"
  assert_json "isolated subnet $subnet_index has no default IPv4 or IPv6 route" \
    '(.RouteTables | length > 0) and all(.RouteTables[].Routes[]?; .DestinationCidrBlock != "0.0.0.0/0" and .DestinationIpv6CidrBlock != "::/0")' \
    "routes-$subnet_index"
done <<< "$subnet_ids"
[[ "$subnet_index" -ge 2 ]] || fail 'fewer than two isolated subnets were returned'

app_secret_names=(
  "auto-shop/staging/$environment/app-runtime"
  "auto-shop/staging/$environment/lambda-auth"
  "auto-shop/staging/$environment/migrations"
)
secret_index=0
for secret_name in "${app_secret_names[@]}"; do
  secret_index=$((secret_index + 1))
  capture_aws_json "secret-$secret_index" secretsmanager list-secret-version-ids --secret-id "$secret_name"
  assert_json "application secret $secret_index exists and has a version" \
    '(.Versions | length > 0)' \
    "secret-$secret_index"
done

pass 'initial metadata and network smoke completed without reading secret values'
