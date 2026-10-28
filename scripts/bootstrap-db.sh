#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/ssm-get-parameters.sh"
# shellcheck source=scripts/private-tmp.sh
source "$script_dir/private-tmp.sh"

NAMESPACE="auto-shop-ops"
JOB_NAME="auto-shop-db-bootstrap"
SQL_CONFIGMAP="auto-shop-db-bootstrap-sql"
SETTINGS_CONFIGMAP="auto-shop-db-bootstrap-settings"
SERVICE_ACCOUNT="auto-shop-db-bootstrap"
ACCOUNT_ID="035611741563"
region="us-east-1"
aws_bin=aws
jq_bin=jq
kubectl_bin=kubectl

if [[ $# -ne 1 ]]; then
  printf 'usage: bootstrap-db.sh <verify|bootstrap|grants|smoke>\n' >&2
  exit 64
fi
phase="$1"
case "$phase" in
  verify|bootstrap|grants|smoke) ;;
  *)
    printf 'usage: bootstrap-db.sh <verify|bootstrap|grants|smoke>\n' >&2
    exit 64
    ;;
esac

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

verify_bundle() {
  local file
  for file in \
    "$script_dir/bootstrap/fetch.sh" \
    "$script_dir/bootstrap/resolve.py" \
    "$script_dir/bootstrap/materialize.py" \
    "$script_dir/bootstrap/psql.sh" \
    "$script_dir/bootstrap/publish.sh" \
    "$script_dir/bootstrap/asm-exec" \
    "$script_dir/bootstrap/job.yaml" \
    "$script_dir/bootstrap/service-account.yaml" \
    "$repo_root/sql/00-bootstrap.sql" \
    "$repo_root/sql/05-migration-default-privileges.sql" \
    "$repo_root/sql/10-lambda-grants.sql"; do
    [[ -r "$file" ]] || fail 'bootstrap source bundle is incomplete'
  done
  [[ "$(grep -Ec '@sha256:[a-f0-9]{64}' "$script_dir/bootstrap/job.yaml")" -eq 3 ]] \
    || fail 'bootstrap images must be pinned by digest'
  if grep -niE 'get-secret-value|batch-get-secret-value' "$script_dir"/bootstrap/*.sh; then
    fail 'direct AWS CLI secret-value reads are prohibited; use asm-exec'
  fi
}

if [[ "$phase" == verify ]]; then
  verify_bundle
  printf 'PASS: pinned bootstrap images and the asm-exec bundle are present\n'
  exit 0
fi

verify_bundle
command -v "$aws_bin" >/dev/null 2>&1 || fail 'AWS CLI is required'
command -v "$jq_bin" >/dev/null 2>&1 || fail 'jq is required'
command -v "$kubectl_bin" >/dev/null 2>&1 || fail 'kubectl is required'

umask 077
tmp_base="${BOOTSTRAP_TMP_BASE:-/dev/shm}"
if [[ "$tmp_base" == /dev/shm ]]; then
  [[ -d /dev/shm && -w /dev/shm ]] || fail 'tmpfs storage is required for bootstrap temporaries'
else
  [[ "${BOOTSTRAP_ALLOW_NON_TMPFS_TMP:-false}" == true ]] || \
    fail 'non-tmpfs bootstrap temporaries require an explicit private directory opt-in'
  if ! tmp_base="$(private_tmp_base "$tmp_base")"; then
    fail 'non-tmpfs bootstrap temporary directory must be private, owned by the caller, and have safe parent directories'
  fi
fi
# Host-side files include SSM metadata, kubeconfig, rendered manifests, Job status, and command logs. Keep a non-tmpfs base private and operator-controlled; secret payloads and AWS workload credentials stay in the Job's memory-backed /work volume.
tmp_dir="$(mktemp -d "${tmp_base%/}/database-bootstrap.XXXXXX")"
chmod 700 "$tmp_dir"
kubectl_ready=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$kubectl_ready" == true ]]; then
    "$kubectl_bin" -n "$NAMESPACE" delete \
      "job/$JOB_NAME" "configmap/$SQL_CONFIGMAP" "configmap/$SETTINGS_CONFIGMAP" \
      "serviceaccount/$SERVICE_ACCOUNT" --ignore-not-found --wait=true --timeout=60s \
      >"$tmp_dir/cleanup.stdout" 2>"$tmp_dir/cleanup.stderr" || true
  fi
  rm -rf "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT

required_parameters=(
  /auto-shop/staging/database/host
  /auto-shop/staging/database/port
  /auto-shop/staging/database/names/hml
  /auto-shop/staging/database/names/prd
  /auto-shop/staging/database/secrets/runtime-hml-arn
  /auto-shop/staging/database/secrets/runtime-prd-arn
  /auto-shop/staging/database/secrets/lambda-hml-arn
  /auto-shop/staging/database/secrets/lambda-prd-arn
  /auto-shop/staging/database/secrets/migrations-hml-arn
  /auto-shop/staging/database/secrets/migrations-prd-arn
  /auto-shop/staging/database/secrets/owner-arn
  /auto-shop/staging/eks/cluster-name
)

if ! "$aws_bin" sts get-caller-identity --query Account --output text \
  >"$tmp_dir/account.txt" 2>"$tmp_dir/account.stderr"; then
  fail 'AWS caller identity preflight failed'
fi
[[ "$(<"$tmp_dir/account.txt")" == "$ACCOUNT_ID" ]] || fail 'AWS caller identity resolved to an unexpected account'

if ! capture_ssm_get_parameters_batched \
  "$tmp_dir/parameters.json" "$aws_bin" "$region" "$jq_bin" "$tmp_dir" \
  "${required_parameters[@]}"; then
  fail 'database SSM metadata query failed'
fi
if ! "$jq_bin" -e \
  '(.InvalidParameters | length == 0) and (.Parameters | length == 12) and all(.Parameters[]; .Type == "String")' \
  "$tmp_dir/parameters.json" >/dev/null 2>&1; then
  parameter_count="$("$jq_bin" '.Parameters | length' "$tmp_dir/parameters.json")"
  invalid_parameters="$("$jq_bin" -r '(.InvalidParameters // []) | join(",")' "$tmp_dir/parameters.json")"
  non_string_parameters="$("$jq_bin" -r '[.Parameters[]? | select(.Type != "String") | .Name] | join(",")' "$tmp_dir/parameters.json")"
  fail "database SSM metadata contract is incomplete (received=${parameter_count}; invalid=${invalid_parameters:-none}; non-string=${non_string_parameters:-none})"
fi

# shellcheck disable=SC2016
parameter_value() {
  printf '%s' "$1" | "$jq_bin" -er --slurpfile response "$tmp_dir/parameters.json" -R \
    '. as $name | [$response[0].Parameters[] | select(.Name == $name) | .Value] | if length == 1 then .[0] else error("expected one SSM parameter match") end'
}

if ! db_host="$(parameter_value /auto-shop/staging/database/host)" \
  || ! db_port="$(parameter_value /auto-shop/staging/database/port)" \
  || ! db_name_hml="$(parameter_value /auto-shop/staging/database/names/hml)" \
  || ! db_name_prd="$(parameter_value /auto-shop/staging/database/names/prd)" \
  || ! runtime_hml_arn="$(parameter_value /auto-shop/staging/database/secrets/runtime-hml-arn)" \
  || ! runtime_prd_arn="$(parameter_value /auto-shop/staging/database/secrets/runtime-prd-arn)" \
  || ! lambda_hml_arn="$(parameter_value /auto-shop/staging/database/secrets/lambda-hml-arn)" \
  || ! lambda_prd_arn="$(parameter_value /auto-shop/staging/database/secrets/lambda-prd-arn)" \
  || ! migrations_hml_arn="$(parameter_value /auto-shop/staging/database/secrets/migrations-hml-arn)" \
  || ! migrations_prd_arn="$(parameter_value /auto-shop/staging/database/secrets/migrations-prd-arn)" \
  || ! owner_secret_arn="$(parameter_value /auto-shop/staging/database/secrets/owner-arn)" \
  || ! cluster_name="$(parameter_value /auto-shop/staging/eks/cluster-name)"; then
  fail 'database SSM metadata could not be parsed'
fi

[[ "$db_host" =~ ^[a-z0-9][a-z0-9.-]*\.us-east-1\.rds\.amazonaws\.com$ ]] || fail 'RDS endpoint metadata is invalid'
[[ "$db_port" == "5432" ]] || fail 'RDS port metadata is invalid'
[[ "$db_name_hml" == "autoshop_hml" && "$db_name_prd" == "autoshop_prd" ]] || fail 'database names do not match the approved contract'
[[ "$cluster_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || fail 'EKS cluster name metadata is invalid'
[[ "$runtime_hml_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/app-runtime-[A-Za-z0-9]{6}$ ]] || fail 'hml runtime secret ARN is invalid'
[[ "$runtime_prd_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/app-runtime-[A-Za-z0-9]{6}$ ]] || fail 'prd runtime secret ARN is invalid'
[[ "$lambda_hml_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/lambda-auth-[A-Za-z0-9]{6}$ ]] || fail 'hml Lambda secret ARN is invalid'
[[ "$lambda_prd_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/lambda-auth-[A-Za-z0-9]{6}$ ]] || fail 'prd Lambda secret ARN is invalid'
[[ "$migrations_hml_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/migrations-[A-Za-z0-9]{6}$ ]] || fail 'hml migrations secret ARN is invalid'
[[ "$migrations_prd_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/migrations-[A-Za-z0-9]{6}$ ]] || fail 'prd migrations secret ARN is invalid'
[[ "$owner_secret_arn" =~ ^arn:aws:secretsmanager:us-east-1:035611741563:secret:rds\!db-[A-Za-z0-9-]+-[A-Za-z0-9]{6}$ ]] || fail 'RDS owner secret ARN is invalid'

settings_file="$tmp_dir/settings.env"
{
  printf 'PHASE=%s\nAWS_REGION=%s\nDB_HOST=%s\nDB_PORT=%s\nDB_NAME_HML=%s\nDB_NAME_PRD=%s\n' \
    "$phase" "$region" "$db_host" "$db_port" "$db_name_hml" "$db_name_prd"
  printf 'OWNER_SECRET_ARN=%s\nRUNTIME_HML_SECRET_ARN=%s\nRUNTIME_PRD_SECRET_ARN=%s\n' \
    "$owner_secret_arn" "$runtime_hml_arn" "$runtime_prd_arn"
  printf 'LAMBDA_HML_SECRET_ARN=%s\nLAMBDA_PRD_SECRET_ARN=%s\n' "$lambda_hml_arn" "$lambda_prd_arn"
  printf 'MIGRATIONS_HML_SECRET_ARN=%s\nMIGRATIONS_PRD_SECRET_ARN=%s\n' "$migrations_hml_arn" "$migrations_prd_arn"
  printf 'ASM_EXEC_MCP_TIMEOUT=30\nPYTHONDONTWRITEBYTECODE=1\nTMPDIR=/work/tmp\n'
} >"$settings_file"
chmod 600 "$settings_file"

if ! "$aws_bin" eks update-kubeconfig --name "$cluster_name" --region "$region" \
  --kubeconfig "$tmp_dir/kubeconfig" >"$tmp_dir/kubeconfig.stdout" 2>"$tmp_dir/kubeconfig.stderr"; then
  fail 'EKS kubeconfig setup failed'
fi
export KUBECONFIG="$tmp_dir/kubeconfig"
kubectl_ready=true

if ! "$kubectl_bin" -n "$NAMESPACE" delete \
  "job/$JOB_NAME" "configmap/$SQL_CONFIGMAP" "configmap/$SETTINGS_CONFIGMAP" \
  "serviceaccount/$SERVICE_ACCOUNT" --ignore-not-found --wait=true --timeout=60s \
  >"$tmp_dir/previous-resources.stdout" 2>"$tmp_dir/previous-resources.stderr"; then
  fail 'stale bootstrap Kubernetes resources could not be removed'
fi

if ! "$kubectl_bin" -n "$NAMESPACE" create configmap "$SQL_CONFIGMAP" \
  --from-file=fetch.sh="$script_dir/bootstrap/fetch.sh" \
  --from-file=resolve.py="$script_dir/bootstrap/resolve.py" \
  --from-file=materialize.py="$script_dir/bootstrap/materialize.py" \
  --from-file=psql.sh="$script_dir/bootstrap/psql.sh" \
  --from-file=publish.sh="$script_dir/bootstrap/publish.sh" \
  --from-file=asm-exec="$script_dir/bootstrap/asm-exec" \
  --from-file=00-bootstrap.sql="$repo_root/sql/00-bootstrap.sql" \
  --from-file=05-migration-default-privileges.sql="$repo_root/sql/05-migration-default-privileges.sql" \
  --from-file=10-lambda-grants.sql="$repo_root/sql/10-lambda-grants.sql" \
  --dry-run=client -o yaml >"$tmp_dir/sql-configmap.yaml" 2>"$tmp_dir/sql-configmap.stderr"; then
  fail 'bootstrap source ConfigMap could not be rendered'
fi
if ! "$kubectl_bin" -n "$NAMESPACE" create configmap "$SETTINGS_CONFIGMAP" \
  --from-env-file="$settings_file" --dry-run=client -o yaml \
  >"$tmp_dir/settings-configmap.yaml" 2>"$tmp_dir/settings-configmap.stderr"; then
  fail 'bootstrap settings ConfigMap could not be rendered'
fi
if ! "$kubectl_bin" apply -f "$script_dir/bootstrap/service-account.yaml" \
  >"$tmp_dir/serviceaccount.stdout" 2>"$tmp_dir/serviceaccount.stderr"; then
  IFS= read -r apply_error <"$tmp_dir/serviceaccount.stderr" || true
  fail "bootstrap ServiceAccount apply failed: ${apply_error:-kubectl returned no diagnostic}"
fi
if ! "$kubectl_bin" apply -f "$tmp_dir/sql-configmap.yaml" \
  >"$tmp_dir/sql-configmap-apply.stdout" 2>"$tmp_dir/sql-configmap-apply.stderr"; then
  IFS= read -r apply_error <"$tmp_dir/sql-configmap-apply.stderr" || true
  fail "bootstrap source ConfigMap apply failed: ${apply_error:-kubectl returned no diagnostic}"
fi
if ! "$kubectl_bin" apply -f "$tmp_dir/settings-configmap.yaml" \
  >"$tmp_dir/settings-configmap-apply.stdout" 2>"$tmp_dir/settings-configmap-apply.stderr"; then
  IFS= read -r apply_error <"$tmp_dir/settings-configmap-apply.stderr" || true
  fail "bootstrap settings ConfigMap apply failed: ${apply_error:-kubectl returned no diagnostic}"
fi
if ! "$kubectl_bin" apply -f "$script_dir/bootstrap/job.yaml" \
  >"$tmp_dir/job-apply.stdout" 2>"$tmp_dir/job-apply.stderr"; then
  fail 'bootstrap Job could not be applied'
fi

deadline=$((SECONDS + 600))
completed=false
while (( SECONDS < deadline )); do
  if ! "$kubectl_bin" -n "$NAMESPACE" get "job/$JOB_NAME" -o json \
    >"$tmp_dir/job-status.json" 2>"$tmp_dir/job-status.stderr"; then
    fail 'bootstrap Job status could not be read'
  fi
  if "$jq_bin" -e '(.status.succeeded // 0) >= 1' "$tmp_dir/job-status.json" >/dev/null 2>&1; then
    completed=true
    break
  fi
  if "$jq_bin" -e '(.status.failed // 0) >= 1' "$tmp_dir/job-status.json" >/dev/null 2>&1; then
    fail "bootstrap Job phase $phase failed; private diagnostics were discarded"
  fi
  sleep 5
done
[[ "$completed" == true ]] || fail "bootstrap Job phase $phase timed out"

printf 'PASS: database Job phase %s completed\n' "$phase"

