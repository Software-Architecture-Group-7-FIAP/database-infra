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
export BOOTSTRAP_KUBECTL_CALLS="$tmp_dir/kubectl-calls.log"

cat > "$bin_dir/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$BOOTSTRAP_AWS_CALLS"

case "$*" in
  'sts get-caller-identity --query Account --output text')
    printf '%s\n' "${BOOTSTRAP_AWS_ACCOUNT:-035611741563}"
    ;;
  '--region us-east-1 ssm get-parameters --names '*)
    cat "$BOOTSTRAP_SSM_FIXTURE"
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

case "$*" in
  *' get job/auto-shop-db-bootstrap -o json')
    if [[ "${BOOTSTRAP_KUBECTL_MODE:-success}" == failed-job ]]; then
      printf '{"status":{"failed":1}}\n'
    else
      printf '{"status":{"succeeded":1}}\n'
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
    {"Name":"/auto-shop/staging/database/secrets/owner-arn","Type":"String","Value":"arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-autoshop-abc123"},
    {"Name":"/auto-shop/staging/eks/cluster-name","Type":"String","Value":"auto-shop-staging"}
  ],
  "InvalidParameters": []
}
PARAMETERS

PATH="$bin_dir:$PATH" bash "$repo_root/scripts/bootstrap-db.sh" bootstrap > "$tmp_dir/bootstrap.out"
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
grep -Fq 'delete job/auto-shop-db-bootstrap' "$BOOTSTRAP_KUBECTL_CALLS" \
  || fail 'bootstrap cleanup did not delete the temporary job'

expect_bootstrap_failure() {
  local label="$1"
  local expected="$2"
  local fixture="$3"
  local account="${4:-035611741563}"
  local fail_kubeconfig="${5:-false}"
  local kubectl_mode="${6:-success}"
  local output="$tmp_dir/$label.out"

  if PATH="$bin_dir:$PATH" \
    BOOTSTRAP_SSM_FIXTURE="$fixture" \
    BOOTSTRAP_AWS_ACCOUNT="$account" \
    BOOTSTRAP_AWS_FAIL_KUBECONFIG="$fail_kubeconfig" \
    BOOTSTRAP_KUBECTL_MODE="$kubectl_mode" \
    bash "$repo_root/scripts/bootstrap-db.sh" bootstrap > "$output" 2>&1; then
    fail "bootstrap unexpectedly accepted $label"
  fi
  grep -Fq "FAIL: $expected" "$output" || fail "bootstrap did not report the expected $label error"
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
  'database names do not match the approved contract'
expect_invalid_parameter invalid_cluster_name /auto-shop/staging/eks/cluster-name 'invalid cluster name' \
  'EKS cluster name metadata is invalid'
expect_invalid_parameter invalid_runtime_hml_arn /auto-shop/staging/database/secrets/runtime-hml-arn arn:invalid \
  'hml runtime secret ARN is invalid'
expect_invalid_parameter invalid_runtime_prd_arn /auto-shop/staging/database/secrets/runtime-prd-arn arn:invalid \
  'prd runtime secret ARN is invalid'
expect_invalid_parameter invalid_lambda_hml_arn /auto-shop/staging/database/secrets/lambda-hml-arn arn:invalid \
  'hml Lambda secret ARN is invalid'
expect_invalid_parameter invalid_lambda_prd_arn /auto-shop/staging/database/secrets/lambda-prd-arn arn:invalid \
  'prd Lambda secret ARN is invalid'
expect_invalid_parameter invalid_owner_arn /auto-shop/staging/database/secrets/owner-arn arn:invalid \
  'RDS owner secret ARN is invalid'

expect_bootstrap_failure kubeconfig_failure 'EKS kubeconfig setup failed' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 true
expect_bootstrap_failure failed_job 'bootstrap Job phase bootstrap failed; private diagnostics were discarded' \
  "$BOOTSTRAP_SSM_FIXTURE" 035611741563 false failed-job

printf 'PASS: bootstrap runtime completed with local AWS and Kubernetes fixtures\n'
