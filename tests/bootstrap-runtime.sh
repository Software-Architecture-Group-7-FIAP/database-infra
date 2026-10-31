#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"
jq_bin="${JQ_BIN:-jq}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export BOOTSTRAP_SSM_FIXTURE="$tmp_dir/parameters.json"
export BOOTSTRAP_AWS_CALLS="$tmp_dir/aws-calls.log"
export BOOTSTRAP_AWS_BATCH_COUNT="$tmp_dir/aws-batch-count"
export BOOTSTRAP_KUBECTL_CALLS="$tmp_dir/kubectl-calls.log"
export BOOTSTRAP_SETTINGS_LOG="$tmp_dir/settings-hml.env"
: > "$BOOTSTRAP_AWS_BATCH_COUNT"

cat > "$bin_dir/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$BOOTSTRAP_AWS_CALLS"

case "$*" in
  'sts get-caller-identity --query Account --output text')
    if [[ "${BOOTSTRAP_AWS_MODE:-success}" == fail-sts ]]; then
      exit 1
    fi
    printf '%s\n' "${BOOTSTRAP_AWS_ACCOUNT:-035611741563}"
    ;;
  '--region us-east-1 ssm get-parameters --names '*)
    if [[ "${BOOTSTRAP_AWS_MODE:-success}" == fail-ssm ]]; then
      exit 1
    fi
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
    requested_json="$(printf '%s\n' "${requested_names[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    batch_index="$(<"$BOOTSTRAP_AWS_BATCH_COUNT")"
    printf '%s\n' "$((batch_index + 1))" > "$BOOTSTRAP_AWS_BATCH_COUNT"
    jq --argjson requested "$requested_json" '
      . as $fixture |
      {
        Parameters: [$fixture.Parameters[] | select(.Name as $name | ($requested | index($name)) != null)],
        InvalidParameters: [$requested[] as $name | select(any($fixture.Parameters[]; .Name == $name) | not) | $name]
      }
    ' "$BOOTSTRAP_SSM_FIXTURE"
    ;;
  'eks update-kubeconfig '*)
    [[ "${BOOTSTRAP_AWS_FAIL_KUBECONFIG:-false}" != true ]]
    ;;
  *)
    printf 'unexpected AWS invocation\n' >&2
    exit 64
    ;;
esac
FAKE_AWS

cat > "$bin_dir/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$BOOTSTRAP_KUBECTL_CALLS"
environment="${BOOTSTRAP_EXPECTED_ENVIRONMENT:-hml}"
job_name="auto-shop-db-bootstrap-$environment"
sql_configmap="auto-shop-db-bootstrap-sql-$environment"
settings_configmap="auto-shop-db-bootstrap-settings-$environment"

case "$*" in
  *" get job/$job_name -o json")
    if [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" == fail-job-status ]]; then
      exit 1
    fi
    if [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" == failed-job ]]; then
      printf '{"status":{"failed":1}}\n'
    else
      printf '{"status":{"succeeded":1}}\n'
    fi
    ;;
  *" delete job/$job_name "*)
    [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" != fail-delete ]]
    ;;
  *" get serviceaccount/auto-shop-db-bootstrap-$environment -o name")
    [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" != missing-serviceaccount ]] || exit 1
    printf 'serviceaccount/auto-shop-db-bootstrap-%s\n' "$environment"
    ;;
  *" create configmap $sql_configmap "*)
    [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" != fail-sql-configmap ]] || exit 1
    printf 'apiVersion: v1\nkind: ConfigMap\n'
    ;;
  *" create configmap $settings_configmap "*)
    [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" != fail-settings-configmap ]] || exit 1
    for argument in "$@"; do
      if [[ "$argument" == --from-env-file=* ]]; then
        cp "${argument#--from-env-file=}" "$BOOTSTRAP_SETTINGS_LOG"
      fi
    done
    printf 'apiVersion: v1\nkind: ConfigMap\n'
    ;;
  *'apply -f '*)
    if [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" == fail-sql-configmap-apply && "$*" == *'/sql-configmap.yaml'* ]]; then
      exit 1
    fi
    if [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" == fail-settings-configmap-apply && "$*" == *'/settings-configmap.yaml'* ]]; then
      exit 1
    fi
    if [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" == fail-job-apply && "$*" == *'/job.yaml'* ]]; then
      exit 1
    fi
    ;;
  *' create configmap '*)
    printf 'apiVersion: v1\nkind: ConfigMap\n'
    ;;
esac
FAKE_KUBECTL

chmod 700 "$bin_dir/aws" "$bin_dir/kubectl"

cat > "$BOOTSTRAP_SSM_FIXTURE" <<'PARAMETERS'
{
  "Parameters": [
    {"Name":"/auto-shop/staging/database/host","Type":"String","Value":"autoshop-db.abc123.us-east-1.rds.amazonaws.com"},
    {"Name":"/auto-shop/staging/database/port","Type":"String","Value":"5432"},
    {"Name":"/auto-shop/staging/database/names/hml","Type":"String","Value":"autoshop_hml"},
    {"Name":"/auto-shop/staging/database/names/prd","Type":"String","Value":"autoshop_prd"},
    {"Name":"/auto-shop/staging/database/secrets/runtime-hml-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/app-runtime-abc123"},
    {"Name":"/auto-shop/staging/database/secrets/runtime-prd-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/app-runtime-def456"},
    {"Name":"/auto-shop/staging/database/secrets/lambda-hml-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/lambda-auth-ghi789"},
    {"Name":"/auto-shop/staging/database/secrets/lambda-prd-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/lambda-auth-jkl012"},
    {"Name":"/auto-shop/staging/database/secrets/migrations-hml-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/migrations-mno345"},
    {"Name":"/auto-shop/staging/database/secrets/migrations-prd-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/migrations-pqr678"},
    {"Name":"/auto-shop/staging/database/secrets/owner-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-autoshop-abc123"},
    {"Name":"/auto-shop/staging/eks/cluster-name","Type":"String","Value":"auto-shop-staging"}
  ],
  "InvalidParameters": []
}
PARAMETERS

: > "$BOOTSTRAP_AWS_BATCH_COUNT"
PATH="$bin_dir:$PATH" bash "$repo_root/scripts/bootstrap-db.sh" bootstrap hml > "$tmp_dir/bootstrap.out"
grep -Fq 'PASS: database Job phase bootstrap completed' "$tmp_dir/bootstrap.out" \
  || { printf 'FAIL: bootstrap runtime did not complete against local fixtures\n' >&2; exit 1; }
grep -Fq 'sts get-caller-identity' "$BOOTSTRAP_AWS_CALLS" \
  || { printf 'FAIL: bootstrap omitted AWS account verification\n' >&2; exit 1; }
grep -Fq 'ssm get-parameters' "$BOOTSTRAP_AWS_CALLS" \
  || { printf 'FAIL: bootstrap omitted SSM metadata lookup\n' >&2; exit 1; }
grep -Fq 'eks update-kubeconfig' "$BOOTSTRAP_AWS_CALLS" \
  || { printf 'FAIL: bootstrap omitted EKS kubeconfig setup\n' >&2; exit 1; }
grep -Fq 'apply -f ' "$BOOTSTRAP_KUBECTL_CALLS" \
  || { printf 'FAIL: bootstrap omitted applying Kubernetes resources\n' >&2; exit 1; }
grep -Fq 'delete job/auto-shop-db-bootstrap-hml' "$BOOTSTRAP_KUBECTL_CALLS" \
  || fail 'bootstrap cleanup did not delete the temporary job'
grep -Fq 'BOOTSTRAP_ROLE_ARN=arn:aws:iam::035611741563:role/auto-shop/auto-shop-staging-db-bootstrap-hml' "$BOOTSTRAP_SETTINGS_LOG" \
  || fail 'HML bootstrap did not derive and pass its environment-specific role ARN'
if grep -Fq 'bootstrap-role-arn' "$BOOTSTRAP_AWS_CALLS"; then
  fail 'HML bootstrap must not request a role ARN SSM parameter'
fi
if grep -Fq 'prd' "$BOOTSTRAP_AWS_CALLS" "$BOOTSTRAP_KUBECTL_CALLS"; then
  fail 'HML bootstrap requested a PRD resource'
fi

: > "$tmp_dir/aws-prd-batch-count"
BOOTSTRAP_EXPECTED_ENVIRONMENT=prd BOOTSTRAP_AWS_CALLS="$tmp_dir/aws-prd-calls.log" \
  BOOTSTRAP_AWS_BATCH_COUNT="$tmp_dir/aws-prd-batch-count" \
  BOOTSTRAP_KUBECTL_CALLS="$tmp_dir/kubectl-prd-calls.log" PATH="$bin_dir:$PATH" \
  BOOTSTRAP_SETTINGS_LOG="$tmp_dir/settings-prd.env" \
  bash "$repo_root/scripts/bootstrap-db.sh" bootstrap prd > "$tmp_dir/bootstrap-prd.out"
grep -Fq 'PASS: database Job phase bootstrap completed' "$tmp_dir/bootstrap-prd.out" \
  || fail 'PRD bootstrap runtime did not complete against local fixtures'
grep -Fq 'get serviceaccount/auto-shop-db-bootstrap-prd' "$tmp_dir/kubectl-prd-calls.log" \
  || fail 'PRD bootstrap did not require its selected service account'
grep -Fq 'BOOTSTRAP_ROLE_ARN=arn:aws:iam::035611741563:role/auto-shop/auto-shop-staging-db-bootstrap-prd' "$tmp_dir/settings-prd.env" \
  || fail 'PRD bootstrap did not derive and pass its environment-specific role ARN'
if grep -Fq 'bootstrap-role-arn' "$tmp_dir/aws-prd-calls.log"; then
  fail 'PRD bootstrap must not request a role ARN SSM parameter'
fi
if grep -Fq 'hml' "$tmp_dir/aws-prd-calls.log" "$tmp_dir/kubectl-prd-calls.log"; then
  fail 'PRD bootstrap requested an HML resource'
fi

expect_bootstrap_failure() {
  local label="$1"
  local expected="$2"
  local fixture="$3"
  local account="${4:-035611741563}"
  local fail_kubeconfig="${5:-false}"
  local kubectl_mode="${6:-success}"
  local aws_mode="${7:-success}"
  local output="$tmp_dir/$label.out"

  : > "$BOOTSTRAP_AWS_BATCH_COUNT"
  if PATH="$bin_dir:$PATH" \
    BOOTSTRAP_SSM_FIXTURE="$fixture" \
    BOOTSTRAP_AWS_ACCOUNT="$account" \
    BOOTSTRAP_AWS_MODE="$aws_mode" \
    BOOTSTRAP_AWS_FAIL_KUBECONFIG="$fail_kubeconfig" \
    BOOTSTRAP_KUBECTL_MODE="$kubectl_mode" \
    bash "$repo_root/scripts/bootstrap-db.sh" bootstrap hml > "$output" 2>&1; then
    fail "bootstrap unexpectedly accepted $label"
  fi
  if ! grep -Fq "FAIL: $expected" "$output"; then
    local observed_failure
    observed_failure="$(sed -nE 's/^(FAIL: [[:alnum:]_ /-]+).*/\1/p' "$output" | head -n 1 || true)"
    if [[ -z "$observed_failure" ]]; then
      if grep -Fq 'jq: error:' "$output"; then
        observed_failure='jq command error'
      elif grep -Fq 'command not found' "$output"; then
        observed_failure='command not found'
      elif [[ -s "$output" ]]; then
        observed_failure='unrecognized output (details suppressed)'
      else
        observed_failure='empty output'
      fi
    fi
    fail "bootstrap $label returned ${observed_failure:-no sanitized failure}, not the expected error"
  fi
}

expect_invalid_parameter() {
  local label="$1"
  local parameter_name="$2"
  local value="$3"
  local expected="$4"
  local fixture="$tmp_dir/$label.json"

  # shellcheck disable=SC2016
  "$jq_bin" --arg name "$parameter_name" --arg value "$value" \
    '.Parameters |= map(if .Name == $name then .Value = $value else . end)' \
    "$BOOTSTRAP_SSM_FIXTURE" > "$fixture"
  expect_bootstrap_failure "$label" "$expected" "$fixture"
}

expect_bootstrap_failure wrong_aws_account 'AWS caller identity resolved to an unexpected account' \
  "$BOOTSTRAP_SSM_FIXTURE" 000000000000

"$jq_bin" '.Parameters |= .[0:9]' "$BOOTSTRAP_SSM_FIXTURE" > "$tmp_dir/incomplete-metadata.json"
expect_bootstrap_failure incomplete_metadata 'database SSM metadata contract is incomplete' \
  "$tmp_dir/incomplete-metadata.json"

expect_invalid_parameter invalid_host /auto-shop/staging/database/host invalid.example \
  'RDS endpoint metadata is invalid'
expect_invalid_parameter invalid_port /auto-shop/staging/database/port 3306 \
  'RDS port metadata is invalid'
expect_invalid_parameter invalid_database_name /auto-shop/staging/database/names/hml wrong_name \
  'database name does not match the selected environment contract'
expect_invalid_parameter invalid_cluster_name /auto-shop/staging/eks/cluster-name 'invalid cluster name' \
  'EKS cluster name metadata is invalid'
expect_invalid_parameter invalid_runtime_hml_arn /auto-shop/staging/database/secrets/runtime-hml-arn arn:invalid \
  'selected runtime secret ARN is invalid'
expect_invalid_parameter invalid_lambda_hml_arn /auto-shop/staging/database/secrets/lambda-hml-arn arn:invalid \
  'selected Lambda secret ARN is invalid'
expect_invalid_parameter invalid_owner_arn /auto-shop/staging/database/secrets/owner-arn arn:invalid \
  'RDS owner secret ARN is invalid'
expect_bootstrap_failure kubeconfig_failure 'EKS kubeconfig setup failed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 true
expect_bootstrap_failure failed_job 'bootstrap Job phase bootstrap failed; private diagnostics were discarded' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false failed-job
expect_bootstrap_failure sts_failure 'AWS caller identity preflight failed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false success fail-sts
expect_bootstrap_failure ssm_failure 'database SSM metadata query failed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false success fail-ssm
expect_bootstrap_failure stale_delete_failure 'stale bootstrap Kubernetes resources could not be removed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-delete
expect_bootstrap_failure sql_configmap_failure 'bootstrap source ConfigMap could not be rendered' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-sql-configmap
expect_bootstrap_failure settings_configmap_failure 'bootstrap settings ConfigMap could not be rendered' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-settings-configmap
expect_bootstrap_failure missing_serviceaccount 'the selected environment service account must be provisioned by k8s-infra before database bootstrap' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false missing-serviceaccount
expect_bootstrap_failure sql_configmap_apply_failure 'bootstrap source ConfigMap apply failed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-sql-configmap-apply
expect_bootstrap_failure settings_configmap_apply_failure 'bootstrap settings ConfigMap apply failed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-settings-configmap-apply
expect_bootstrap_failure job_apply_failure 'bootstrap Job could not be applied' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-job-apply
expect_bootstrap_failure job_status_failure 'bootstrap Job status could not be read' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false fail-job-status

printf 'PASS: bootstrap runtime completed with local AWS and Kubernetes fixtures\n'
