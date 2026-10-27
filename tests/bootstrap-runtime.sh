#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

export BOOTSTRAP_SSM_FIXTURE="$tmp_dir/parameters.json"
export BOOTSTRAP_AWS_CALLS="$tmp_dir/aws-calls.log"
export BOOTSTRAP_KUBECTL_CALLS="$tmp_dir/kubectl-calls.log"

cat > "$bin_dir/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$BOOTSTRAP_AWS_CALLS"

case "$*" in
  'sts get-caller-identity --query Account --output text')
    printf '%s\n' '035611741563'
    ;;
  '--region us-east-1 ssm get-parameters --names '*)
    cat "$BOOTSTRAP_SSM_FIXTURE"
    ;;
  'eks update-kubeconfig '*)
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
    printf '{"status":{"succeeded":1}}\n'
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
  || { printf 'FAIL: bootstrap cleanup did not delete the temporary job\n' >&2; exit 1; }

printf 'PASS: bootstrap runtime completed with local AWS and Kubernetes fixtures\n'
