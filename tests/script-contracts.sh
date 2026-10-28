#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bash "$repo_root/tests/private-tmp.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

record_critical_branch() {
  if [[ -n "${SHELL_COVERAGE_BRANCH_REPORT:-}" ]]; then
    printf '%s\n' "$1" >> "$SHELL_COVERAGE_BRANCH_REPORT"
  fi
}

assert_secret_value_apis_denied() {
  local fake_aws="$1"
  local status

  if "$fake_aws" secretsmanager get-secret-value --secret-id fixture >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 98 ]] || fail 'AWS fixture did not explicitly deny Secrets Manager value reads'

  if "$fake_aws" ssm get-parameters-by-path --path /fixture >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 98 ]] || fail 'AWS fixture did not explicitly deny broad SSM reads'
}

python3 "$repo_root/tests/materialize-contract.py"

for script in plan-summary.sh bootstrap-db.sh smoke.sh orphans.sh ssm-get-parameters.sh; do
  [[ -f "$repo_root/scripts/$script" ]] || fail "missing operations script: $script"
done

if rg -n '^[[:space:]]*ingress([[:space:]]*=|[[:space:]]*\{)' "$repo_root/modules/db-network/main.tf"; then
  fail 'the security group must not own ingress rules inline'
fi
rg -q '^resource "aws_vpc_security_group_ingress_rule" "this"' "$repo_root/modules/db-network/main.tf" || fail 'standalone ingress rule ownership is missing'
if rg -n '^[[:space:]]*dynamic[[:space:]]+"(ingress|egress)"' "$repo_root/modules/db-network/main.tf"; then
  fail 'dynamic inline security group rules are prohibited'
fi
if rg -n '^[[:space:]]*kms_key_id[[:space:]]*=' "$repo_root/modules/db-instance/main.tf"; then
  fail 'RDS must omit kms_key_id so the provider selects the AWS-managed storage key'
fi

jq_bin="${JQ_BIN:-jq}"
command -v "$jq_bin" >/dev/null 2>&1 || fail 'jq is required'

"$jq_bin" -n '{
  format_version: "1.2",
  resource_changes: [{
    address: "module.instance.aws_db_instance.this",
    change: { actions: ["create"] }
  }],
  output_changes: {
    db_host: { after: "postgresql://app:CANARY_SECRET_VALUE@db.invalid/autoshop_hml" }
  }
}' > "$tmp_dir/plan.json"

bash "$repo_root/scripts/plan-summary.sh" "$tmp_dir/plan.json" > "$tmp_dir/summary.txt"
grep -Fq 'module.instance.aws_db_instance.this' "$tmp_dir/summary.txt" || fail 'plan summary omitted the resource address'
if grep -Fq 'CANARY_SECRET_VALUE' "$tmp_dir/summary.txt"; then
  fail 'plan summary leaked an output value'
fi
if bash "$repo_root/scripts/plan-summary.sh" > "$tmp_dir/summary-no-arguments.out" 2>&1; then
  fail 'plan summary accepted a call without a plan path'
fi
grep -Fq 'FAIL: usage: plan-summary.sh' "$tmp_dir/summary-no-arguments.out" || fail 'plan summary usage error was not reported'
if bash "$repo_root/scripts/plan-summary.sh" "$tmp_dir/missing-plan.json" > "$tmp_dir/summary-unreadable.out" 2>&1; then
  fail 'plan summary accepted a missing plan file'
fi
grep -Fq 'FAIL: plan JSON is not readable' "$tmp_dir/summary-unreadable.out" || fail 'plan summary unreadable-file error was not reported'
printf '{"format_version":"1.2","resource_changes":{}}\n' > "$tmp_dir/invalid-plan-shape.json"
if bash "$repo_root/scripts/plan-summary.sh" "$tmp_dir/invalid-plan-shape.json" > "$tmp_dir/summary-invalid.out" 2>&1; then
  fail 'plan summary accepted an invalid plan shape'
fi
grep -Fq 'FAIL: plan JSON has an invalid shape' "$tmp_dir/summary-invalid.out" || fail 'plan summary invalid-shape error was not reported'
if JQ_BIN=missing-jq bash "$repo_root/scripts/plan-summary.sh" "$tmp_dir/plan.json" > "$tmp_dir/summary-missing-jq.out" 2>&1; then
  fail 'plan summary accepted an unavailable jq executable'
fi
grep -Fq 'FAIL: jq is required' "$tmp_dir/summary-missing-jq.out" || fail 'plan summary missing-jq error was not reported'

mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/aws" <<'SH'
#!/usr/bin/env bash
touch "$ORCHESTRATION_TEST_AWS_CALLED"
exit 99
SH
cat > "$tmp_dir/bin/kubectl" <<'SH'
#!/usr/bin/env bash
touch "$ORCHESTRATION_TEST_KUBECTL_CALLED"
exit 99
SH
chmod +x "$tmp_dir/bin/aws" "$tmp_dir/bin/kubectl"

export PATH="$tmp_dir/bin:$PATH"
export ORCHESTRATION_TEST_AWS_CALLED="$tmp_dir/aws-called"
export ORCHESTRATION_TEST_KUBECTL_CALLED="$tmp_dir/kubectl-called"

if ! bash "$repo_root/scripts/bootstrap-db.sh" verify >"$tmp_dir/bootstrap-verify.out" 2>&1; then
  fail 'bootstrap bundle verification failed'
fi
record_critical_branch bootstrap_bundle_static_verify

for phase in bootstrap grants; do
  if bash "$repo_root/scripts/bootstrap-db.sh" "$phase" >"$tmp_dir/bootstrap-$phase.out" 2>&1; then
    fail "bootstrap preflight unexpectedly succeeded without an AWS fixture"
  else
    status=$?
    [[ "$status" -eq 1 ]] || fail "bootstrap phase returned $status instead of a sanitized preflight failure"
  fi
  if grep -Fq "CANARY_SECRET_VALUE" "$tmp_dir/bootstrap-$phase.out"; then
    fail "bootstrap script leaked canary content for $phase"
  fi
done
record_critical_branch bootstrap_runtime_preflight_fails_closed

if bash "$repo_root/scripts/smoke.sh" full >"$tmp_dir/smoke-full.out" 2>&1; then
  fail 'full smoke unexpectedly succeeded without an AWS fixture'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "full smoke returned $status instead of a sanitized runtime failure"
fi
record_critical_branch smoke_full_runtime_job_preflight

bash "$repo_root/scripts/orphans.sh" --help > "$tmp_dir/orphans-help.out"
grep -Fq "orphans.sh" "$tmp_dir/orphans-help.out" || fail "orphan check help omitted usage"
if bash "$repo_root/scripts/orphans.sh" > "$tmp_dir/orphans-no-arguments.out" 2>&1; then
  fail 'orphan scan accepted a call without a manifest path'
fi
grep -Fq 'usage: orphans.sh' "$tmp_dir/orphans-no-arguments.out" || fail 'orphan scan usage error was not reported'

[[ -e "$ORCHESTRATION_TEST_AWS_CALLED" ]] || fail "bootstrap preflight did not reach the fake AWS CLI"
[[ ! -e "$ORCHESTRATION_TEST_KUBECTL_CALLED" ]] || fail "failed AWS preflight reached kubectl"

cat > "$tmp_dir/bin/orphan-aws" <<'SH'
#!/usr/bin/env bash
arguments="$*"
case "$arguments" in
  *"get-secret-value"*|*"get-parameters-by-path"*|*"GetSecretValue"*|*"GetParametersByPath"*) printf 'prohibited API request\n' >&2; exit 98 ;;
  *"resourcegroupstaggingapi get-resources"*)
    case "${ORPHAN_TEST_TAG_MODE:-empty}" in
      empty) printf '{"ResourceTagMappingList":[]}\n' ;;
      present) printf '{"ResourceTagMappingList":[{"ResourceARN":"arn:aws:rds:us-east-1:035611741563:db:orphan"}]}\n' ;;
      query-error)
        printf 'AccessDeniedException: resource metadata query denied\n' >&2
        exit 255
        ;;
      *) printf 'unexpected orphan tag mode\n' >&2; exit 97 ;;
    esac
    ;;
  *"rds describe-db-instances"*) printf 'DBInstanceNotFound: no such staging instance\n' >&2; exit 255 ;;
  *"rds describe-db-snapshots"*) printf '{"DBSnapshots":[]}\n' ;;
  *"rds describe-db-instance-automated-backups"*) printf '{"DBInstanceAutomatedBackups":[]}\n' ;;
  *"rds describe-db-subnet-groups"*) printf 'DBSubnetGroupNotFoundFault: no such subnet group\n' >&2; exit 255 ;;
  *"rds describe-db-parameter-groups"*) printf 'DBParameterGroupNotFound: no such parameter group\n' >&2; exit 255 ;;
  *"ec2 describe-security-groups"*) printf 'InvalidGroup.NotFound: no such security group\n' >&2; exit 255 ;;
  *"secretsmanager describe-secret"*)
    case "${ORPHAN_TEST_SECRET_MODE:-absent}" in
      absent)
        printf 'ResourceNotFoundException: no such secret\n' >&2
        exit 255
        ;;
      pending|timeout)
        secret_id=""
        previous=""
        for argument in "$@"; do
          if [[ "$previous" == --secret-id ]]; then
            secret_id="$argument"
            break
          fi
          previous="$argument"
        done
        safe_id="$(printf '%s' "$secret_id" | tr '/-:' '___')"
        count_file="$ORCHESTRATION_TEST_SECRET_COUNT_DIR/$safe_id"
        count=0
        if [[ -r "$count_file" ]]; then
          read -r count < "$count_file"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$count_file"
        if [[ "$ORPHAN_TEST_SECRET_MODE" == pending && "$count" -gt 2 ]]; then
          printf 'ResourceNotFoundException: no such secret\n' >&2
          exit 255
        fi
        printf '2026-10-26T22:00:00Z\n'
        ;;
      query-error)
        printf 'AccessDeniedException: metadata query denied\n' >&2
        exit 255
        ;;
      *)
        printf 'unexpected orphan secret mode\n' >&2
        exit 97
        ;;
    esac
    ;;
  *"iam get-role"*|*"iam get-policy"*) printf 'NoSuchEntity: no such IAM resource\n' >&2; exit 255 ;;
  *"ssm get-parameter --name"*) printf '{"Parameter":{"Value":"auto-shop-staging"}}\n' ;;
  *"eks describe-cluster"*) printf '{"cluster":{"name":"auto-shop-staging"}}\n' ;;
  *"eks list-pod-identity-associations"*) printf '{"associations":[]}\n' ;;
  *"ssm get-parameters"*)
    requested_name_count=0
    reading_names=false
    for argument in "$@"; do
      if [[ "$argument" == --names ]]; then
        reading_names=true
        continue
      fi
      if [[ "$argument" == --* ]]; then
        reading_names=false
      elif [[ "$reading_names" == true ]]; then
        requested_name_count=$((requested_name_count + 1))
      fi
    done
    [[ "$requested_name_count" -le 10 ]] || { printf 'ValidationException: GetParameters accepts at most 10 names\n' >&2; exit 254; }
    printf '%s\n' "$requested_name_count" >> "$ORCHESTRATION_TEST_SSM_BATCH_LOG"
    printf '{"Parameters":[],"InvalidParameters":[]}\n'
    ;;
  *) printf 'unexpected AWS metadata command\n' >&2; exit 97 ;;
esac
SH
chmod +x "$tmp_dir/bin/orphan-aws"
assert_secret_value_apis_denied "$tmp_dir/bin/orphan-aws"
printf '{}\n' > "$tmp_dir/manifest.json"

if bash "$repo_root/scripts/orphans.sh" "$tmp_dir/missing-manifest.json" > "$tmp_dir/orphans-missing-manifest.out" 2>&1; then
  fail 'orphan scan accepted a missing Terraform manifest'
else
  grep -Fq 'FAIL: Terraform metadata manifest is not readable' "$tmp_dir/orphans-missing-manifest.out" || fail 'orphan scan did not reject a missing manifest'
fi

printf '{"connection_string":"postgresql://synthetic-fixture"}\n' > "$tmp_dir/unsafe-manifest.json"
if bash "$repo_root/scripts/orphans.sh" "$tmp_dir/unsafe-manifest.json" > "$tmp_dir/orphans-unsafe-manifest.out" 2>&1; then
  fail 'orphan scan accepted a manifest containing a connection string'
else
  grep -Fq 'FAIL: Terraform metadata manifest is invalid or contains a prohibited connection value' "$tmp_dir/orphans-unsafe-manifest.out" || fail 'orphan scan did not reject connection values in a manifest'
fi

if AWS_BIN=missing-orphan-aws bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$tmp_dir/orphans-missing-aws.out" 2>&1; then
  fail 'orphan scan accepted a missing AWS CLI'
else
  grep -Fq 'FAIL: aws CLI is required' "$tmp_dir/orphans-missing-aws.out" || fail 'orphan scan did not report a missing AWS CLI'
fi

if JQ_BIN=missing-orphan-jq AWS_BIN="$tmp_dir/bin/orphan-aws" \
  bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$tmp_dir/orphans-missing-jq.out" 2>&1; then
  fail 'orphan scan accepted a missing jq executable'
else
  grep -Fq 'FAIL: jq is required' "$tmp_dir/orphans-missing-jq.out" || fail 'orphan scan did not report a missing jq executable'
fi

: > "$tmp_dir/orphans-batches.log"
ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/orphans-batches.log" AWS_BIN="$tmp_dir/bin/orphan-aws" \
  bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$tmp_dir/orphans.out"
grep -Fq 'PASS: database-infra orphan scan completed' "$tmp_dir/orphans.out" || fail 'orphan scan did not complete against empty fixtures'
printf '10\n6\n' > "$tmp_dir/expected-ssm-batches.log"
cmp -s "$tmp_dir/expected-ssm-batches.log" "$tmp_dir/orphans-batches.log" || fail 'orphan scan did not query all published parameters in 10-name batches'
if grep -Fq 'CANARY_SECRET_VALUE' "$tmp_dir/orphans.out"; then
  fail 'orphan scan leaked a canary value'
fi

if ORPHAN_TEST_TAG_MODE=present AWS_BIN="$tmp_dir/bin/orphan-aws" \
  bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$tmp_dir/orphans-tagged-resource.out" 2>&1; then
  fail 'orphan scan accepted a tagged resource still present in AWS'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "tagged resource detection returned $status instead of a closed failure"
  grep -Fq 'FAIL: orphan detected or ownership query incomplete: all tagged database-infra resources' \
    "$tmp_dir/orphans-tagged-resource.out" || fail 'orphan scan did not reject a tagged resource'
fi

if ORPHAN_TEST_TAG_MODE=query-error AWS_BIN="$tmp_dir/bin/orphan-aws" \
  bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$tmp_dir/orphans-tag-query-error.out" 2>&1; then
  fail 'orphan scan accepted a failed AWS ownership query'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "ownership query failure returned $status instead of a closed failure"
  grep -Fq 'FAIL: tagged_resources metadata query failed' "$tmp_dir/orphans-tag-query-error.out" ||
    fail 'orphan scan did not report an AWS ownership query failure'
fi

run_orphan_secret_case() {
  local mode="$1"
  local expected="$2"
  local output="$tmp_dir/orphans-$mode.out"
  local count_dir="$tmp_dir/orphans-$mode-counts"
  mkdir -p "$count_dir"

  if ORPHAN_TEST_SECRET_MODE="$mode" \
    ORCHESTRATION_TEST_SECRET_COUNT_DIR="$count_dir" \
    ORPHAN_SECRET_DELETE_MAX_ATTEMPTS=3 \
    ORPHAN_SECRET_DELETE_INTERVAL_SECONDS=0 \
    ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/orphans-$mode-batches.log" \
    AWS_BIN="$tmp_dir/bin/orphan-aws" \
    bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$output" 2>&1; then
    [[ "$expected" == pass ]] || fail "orphan polling unexpectedly accepted $mode"
    grep -Fq 'PASS: database-infra orphan scan completed' "$output" || fail "orphan polling did not complete for $mode"
  else
    local status=$?
    [[ "$expected" != pass ]] || fail "orphan polling failed for $mode with status $status"
    grep -Fq "$expected" "$output" || fail "orphan polling did not report the expected $mode result"
  fi

  if grep -Fq 'CANARY_SECRET_VALUE' "$output"; then
    fail "orphan polling leaked a canary value for $mode"
  fi

  if [[ "$expected" == pass ]]; then
    cmp -s "$tmp_dir/expected-ssm-batches.log" "$tmp_dir/orphans-$mode-batches.log" || fail "orphan polling did not batch all published parameters for $mode"
  fi

  case "$mode" in
    absent) record_critical_branch secret_absent_metadata ;;
    pending) record_critical_branch secret_pending_then_absent ;;
    timeout) record_critical_branch secret_pending_timeout_closed ;;
    query-error) record_critical_branch secret_query_error_closed ;;
  esac
}

run_orphan_secret_case absent pass
run_orphan_secret_case pending pass
run_orphan_secret_case timeout 'pending deletion after bounded metadata polling'
run_orphan_secret_case query-error 'metadata query failed for a reason other than not found'

run_invalid_orphan_poll_setting() {
  local setting="$1"
  local value="$2"
  local expected="$3"
  local output="$tmp_dir/orphans-invalid-${setting}.out"

  if env "$setting=$value" AWS_BIN="$tmp_dir/bin/orphan-aws" \
    bash "$repo_root/scripts/orphans.sh" "$tmp_dir/manifest.json" > "$output" 2>&1; then
    fail "orphan polling accepted out-of-range $setting"
  else
    local status=$?
    [[ "$status" -eq 1 ]] || fail "invalid $setting returned $status instead of a closed failure"
    grep -Fq "$expected" "$output" || fail "invalid $setting did not report its bounded range"
  fi
}

run_invalid_orphan_poll_setting ORPHAN_SECRET_DELETE_MAX_ATTEMPTS \
  18446744073709551619 'between 1 and 60'
run_invalid_orphan_poll_setting ORPHAN_SECRET_DELETE_INTERVAL_SECONDS \
  18446744073709551616 'between 0 and 10'

mkdir -p "$tmp_dir/smoke-fixtures"
cat > "$tmp_dir/smoke-fixtures/parameters.json" <<'JSON'
{
  "InvalidParameters": [],
  "Parameters": [
    {"Name":"/auto-shop/staging/database/host","Type":"String","Value":"db.internal"},
    {"Name":"/auto-shop/staging/database/port","Type":"String","Value":"5432"},
    {"Name":"/auto-shop/staging/database/security-group-id","Type":"String","Value":"sg-a123"},
    {"Name":"/auto-shop/staging/database/names/hml","Type":"String","Value":"autoshop_hml"},
    {"Name":"/auto-shop/staging/database/names/prd","Type":"String","Value":"autoshop_prd"},
    {"Name":"/auto-shop/staging/database/secrets/runtime-hml-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/app-runtime"},
    {"Name":"/auto-shop/staging/database/secrets/runtime-prd-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/app-runtime"},
    {"Name":"/auto-shop/staging/database/secrets/lambda-hml-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/lambda-auth"},
    {"Name":"/auto-shop/staging/database/secrets/lambda-prd-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/lambda-auth"},
    {"Name":"/auto-shop/staging/database/secrets/migrations-hml-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/migrations"},
    {"Name":"/auto-shop/staging/database/secrets/migrations-prd-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/migrations"},
    {"Name":"/auto-shop/staging/database/secrets/owner-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-example"},
    {"Name":"/auto-shop/staging/database/iam/lambda-read-policy-arn/hml","Type":"String","Value":"arn:aws:iam::035611741563:policy/auto-shop/auto-shop-staging-db-read-lambda-hml"},
    {"Name":"/auto-shop/staging/database/iam/lambda-read-policy-arn/prd","Type":"String","Value":"arn:aws:iam::035611741563:policy/auto-shop/auto-shop-staging-db-read-lambda-prd"},
    {"Name":"/auto-shop/staging/database/iam/migrations-hml-read-policy-arn","Type":"String","Value":"arn:aws:iam::035611741563:policy/auto-shop/auto-shop-staging-db-read-migrations-hml"},
    {"Name":"/auto-shop/staging/database/iam/migrations-prd-read-policy-arn","Type":"String","Value":"arn:aws:iam::035611741563:policy/auto-shop/auto-shop-staging-db-read-migrations-prd"}
  ]
}
JSON
cat > "$tmp_dir/smoke-fixtures/instance.json" <<'JSON'
{"DBInstances":[{"DBInstanceStatus":"available","PubliclyAccessible":false,"MultiAZ":false,"Engine":"postgres","EngineVersion":"16.15","StorageEncrypted":true,"BackupRetentionPeriod":1,"DeletionProtection":false}]}
JSON
cat > "$tmp_dir/smoke-fixtures/upstream-subnets.json" <<'JSON'
{"Parameter":{"Type":"StringList","Value":"subnet-111,subnet-222"}}
JSON
cat > "$tmp_dir/smoke-fixtures/subnet-group.json" <<'JSON'
{"DBSubnetGroups":[{"Subnets":[{"SubnetIdentifier":"subnet-111"},{"SubnetIdentifier":"subnet-222"}]}]}
JSON
cat > "$tmp_dir/smoke-fixtures/security-group.json" <<'JSON'
{"SecurityGroups":[{"IpPermissions":[{"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,"UserIdGroupPairs":[{"GroupId":"sg-1"}],"IpRanges":[],"Ipv6Ranges":[],"PrefixListIds":[]},{"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,"UserIdGroupPairs":[{"GroupId":"sg-2"}],"IpRanges":[],"Ipv6Ranges":[],"PrefixListIds":[]}],"IpPermissionsEgress":[]}]}
JSON
cat > "$tmp_dir/smoke-fixtures/routes.json" <<'JSON'
{"RouteTables":[{"Routes":[{"DestinationCidrBlock":"10.0.0.0/16"}]}]}
JSON
cat > "$tmp_dir/smoke-fixtures/secret-versions.json" <<'JSON'
{"Versions":[{"VersionId":"version-metadata-only"}]}
JSON
cat > "$tmp_dir/bin/smoke-aws" <<'SH'
#!/usr/bin/env bash
arguments="$*"
case "$arguments" in
  *"get-secret-value"*|*"get-parameters-by-path"*|*"GetSecretValue"*|*"GetParametersByPath"*) printf 'prohibited AWS API request\n' >&2; exit 98 ;;
  *"ssm get-parameters"*)
    requested_names=()
    reading_names=false
    for argument in "$@"; do
      if [[ "$argument" == --names ]]; then
        reading_names=true
        continue
      fi
      if [[ "$argument" == --* ]]; then
        reading_names=false
      elif [[ "$reading_names" == true ]]; then
        requested_names+=("$argument")
      fi
    done
    [[ "${#requested_names[@]}" -le 10 ]] || { printf 'ValidationException: GetParameters accepts at most 10 names\n' >&2; exit 254; }
    printf '%s\n' "${#requested_names[@]}" >> "$ORCHESTRATION_TEST_SSM_BATCH_LOG"
    batch_index="$(wc -l < "$ORCHESTRATION_TEST_SSM_BATCH_LOG")"
    if [[ "${SMOKE_TEST_FAILURE:-}" == ssm_second_batch && "$batch_index" -eq 2 ]]; then
      printf 'AccessDeniedException: metadata query denied\n' >&2
      exit 255
    fi
    requested_names_json="$(printf '%s\n' "${requested_names[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    jq --argjson requested "$requested_names_json" --arg failure "${SMOKE_TEST_FAILURE:-}" '
      . as $fixture |
      {
        Parameters: [$fixture.Parameters[]? | select(.Name as $name | ($requested | index($name)) != null)
          | if $failure == "invalid_security_group_id" and .Name == "/auto-shop/staging/database/security-group-id" then .Value = "invalid" else . end],
        InvalidParameters: [$requested[] as $name | select(any($fixture.Parameters[]?; .Name == $name) | not)]
      }
    ' "$SMOKE_FIXTURE_DIR/parameters.json"
    ;;
  *"rds describe-db-instances"*)
    if [[ "${SMOKE_TEST_FAILURE:-}" == invalid_rds_contract ]]; then
      jq '.DBInstances[0].PubliclyAccessible = true' "$SMOKE_FIXTURE_DIR/instance.json"
    else
      cat "$SMOKE_FIXTURE_DIR/instance.json"
    fi
    ;;
  *"ssm get-parameter"*) cat "$SMOKE_FIXTURE_DIR/upstream-subnets.json" ;;
  *"rds describe-db-subnet-groups"*)
    if [[ "${SMOKE_TEST_FAILURE:-}" == mismatched_subnet_group ]]; then
      jq '.DBSubnetGroups[0].Subnets[0].SubnetIdentifier = "subnet-other"' "$SMOKE_FIXTURE_DIR/subnet-group.json"
    else
      cat "$SMOKE_FIXTURE_DIR/subnet-group.json"
    fi
    ;;
  *"ec2 describe-security-groups"*) cat "$SMOKE_FIXTURE_DIR/security-group.json" ;;
  *"ec2 describe-route-tables"*) cat "$SMOKE_FIXTURE_DIR/routes.json" ;;
  *"secretsmanager list-secret-version-ids"*)
    if [[ "${SMOKE_TEST_FAILURE:-}" == secret_metadata ]]; then
      printf 'AccessDeniedException: metadata query denied\n' >&2
      exit 255
    fi
    cat "$SMOKE_FIXTURE_DIR/secret-versions.json"
    ;;
  *) printf 'unexpected AWS metadata command\n' >&2; exit 97 ;;
esac
SH
chmod +x "$tmp_dir/bin/smoke-aws"
assert_secret_value_apis_denied "$tmp_dir/bin/smoke-aws"
record_critical_branch fake_aws_forbids_secret_and_broad_ssm_reads
SMOKE_FIXTURE_DIR="$tmp_dir/smoke-fixtures" ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/smoke-batches.log" AWS_BIN="$tmp_dir/bin/smoke-aws" \
  TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-initial.out"
grep -Fq 'PASS: initial metadata and network smoke completed' "$tmp_dir/smoke-initial.out" || fail 'initial smoke did not complete against valid fixtures'
cmp -s "$tmp_dir/expected-ssm-batches.log" "$tmp_dir/smoke-batches.log" || fail 'initial smoke did not query all output parameters in 10-name batches'
if grep -Fq 'CANARY_SECRET_VALUE' "$tmp_dir/smoke-initial.out"; then
  fail 'initial smoke leaked a canary value'
fi

if SMOKE_TEST_FAILURE=secret_metadata \
  SMOKE_FIXTURE_DIR="$tmp_dir/smoke-fixtures" ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/smoke-partial-batches.log" AWS_BIN="$tmp_dir/bin/smoke-aws" \
  TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-partial-failure.out" 2>&1; then
  fail 'initial smoke unexpectedly accepted a secret metadata query failure after earlier checks passed'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "partial smoke failure returned $status instead of a closed failure"
  grep -Fq 'metadata query failed' "$tmp_dir/smoke-partial-failure.out" || fail 'partial smoke failure did not report a metadata query error'
fi
record_critical_branch smoke_partial_metadata_failure
if grep -Fq 'CANARY_SECRET_VALUE' "$tmp_dir/smoke-partial-failure.out"; then
  fail 'partial smoke failure leaked a canary value'
fi

if SMOKE_TEST_FAILURE=invalid_rds_contract \
  SMOKE_FIXTURE_DIR="$tmp_dir/smoke-fixtures" ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/smoke-invalid-rds-batches.log" AWS_BIN="$tmp_dir/bin/smoke-aws" \
  TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-invalid-rds.out" 2>&1; then
  fail 'initial smoke accepted a publicly accessible RDS instance'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "invalid RDS contract returned $status instead of a closed failure"
  grep -Fq 'RDS is available, private, encrypted PostgreSQL 16.15 Single-AZ with one-day retention invariant failed' "$tmp_dir/smoke-invalid-rds.out" || fail 'invalid RDS contract was not rejected'
fi

if SMOKE_TEST_FAILURE=mismatched_subnet_group \
  SMOKE_FIXTURE_DIR="$tmp_dir/smoke-fixtures" ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/smoke-invalid-subnet-batches.log" AWS_BIN="$tmp_dir/bin/smoke-aws" \
  TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-invalid-subnet.out" 2>&1; then
  fail 'initial smoke accepted a subnet group that differs from the upstream subnet list'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "invalid subnet group returned $status instead of a closed failure"
  grep -Fq 'RDS subnet group does not match the upstream isolated subnet list' "$tmp_dir/smoke-invalid-subnet.out" || fail 'invalid subnet group was not rejected'
fi

if SMOKE_TEST_FAILURE=ssm_second_batch \
  SMOKE_FIXTURE_DIR="$tmp_dir/smoke-fixtures" ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/smoke-ssm-failure-batches.log" AWS_BIN="$tmp_dir/bin/smoke-aws" \
  TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-ssm-failure.out" 2>&1; then
  fail 'initial smoke unexpectedly accepted an SSM failure in the second name batch'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "SSM batch failure returned $status instead of a closed failure"
  grep -Fq 'SSM parameter metadata query failed' "$tmp_dir/smoke-ssm-failure.out" || fail 'SSM batch failure did not report a metadata query error'
fi
cmp -s "$tmp_dir/expected-ssm-batches.log" "$tmp_dir/smoke-ssm-failure-batches.log" || fail 'initial smoke did not fail after attempting the second 10-name batch'
record_critical_branch smoke_ssm_second_batch_failure
if grep -Fq 'CANARY_SECRET_VALUE' "$tmp_dir/smoke-ssm-failure.out"; then
  fail 'SSM batch failure leaked a canary value'
fi

if SMOKE_TEST_FAILURE=invalid_security_group_id \
  SMOKE_FIXTURE_DIR="$tmp_dir/smoke-fixtures" ORCHESTRATION_TEST_SSM_BATCH_LOG="$tmp_dir/smoke-invalid-sg-batches.log" AWS_BIN="$tmp_dir/bin/smoke-aws" \
  TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-invalid-sg.out" 2>&1; then
  fail 'initial smoke accepted an invalid published security group ID'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "invalid security group ID returned $status instead of a closed failure"
  grep -Fq 'published database security group ID is invalid' "$tmp_dir/smoke-invalid-sg.out" || fail 'invalid security group ID was not rejected at the published contract boundary'
fi

if bash "$repo_root/scripts/smoke.sh" invalid-phase > "$tmp_dir/smoke-invalid-phase.out" 2>&1; then
  fail 'smoke accepted an unsupported phase'
else
  status=$?
  [[ "$status" -eq 64 ]] || fail "unsupported smoke phase returned $status instead of usage status 64"
  grep -Fq 'usage: smoke.sh [initial|full]' "$tmp_dir/smoke-invalid-phase.out" || fail 'unsupported smoke phase did not report usage'
fi

if bash "$repo_root/scripts/smoke.sh" initial extra > "$tmp_dir/smoke-extra-arguments.out" 2>&1; then
  fail 'smoke accepted more than one phase argument'
else
  status=$?
  [[ "$status" -eq 64 ]] || fail "extra smoke arguments returned $status instead of usage status 64"
  grep -Fq 'usage: smoke.sh [initial|full]' "$tmp_dir/smoke-extra-arguments.out" || fail 'extra smoke arguments did not report usage'
fi

if AWS_BIN=missing-smoke-aws bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-missing-aws.out" 2>&1; then
  fail 'smoke accepted a missing AWS CLI'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "missing AWS CLI returned $status instead of a closed failure"
  grep -Fq 'FAIL: aws CLI is required' "$tmp_dir/smoke-missing-aws.out" || fail 'missing AWS CLI did not report a clear preflight error'
fi

if AWS_BIN="$tmp_dir/bin/smoke-aws" JQ_BIN=missing-smoke-jq \
  bash "$repo_root/scripts/smoke.sh" initial > "$tmp_dir/smoke-missing-jq.out" 2>&1; then
  fail 'smoke accepted a missing jq executable'
else
  status=$?
  [[ "$status" -eq 1 ]] || fail "missing jq returned $status instead of a closed failure"
  grep -Fq 'FAIL: jq is required' "$tmp_dir/smoke-missing-jq.out" || fail 'missing jq did not report a clear preflight error'
fi

printf 'PASS: summaries redact plan values and unverified secret resolution fails closed before network access\n'
