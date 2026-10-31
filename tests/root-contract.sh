#!/usr/bin/env bash
# shellcheck disable=SC2016
# This file greps for literal Terraform/Markdown text containing '$'; single quotes are intentional.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
staging_root="$repo_root/envs/staging/database"
hml_root="$repo_root/envs/hml/database"
prd_root="$repo_root/envs/prd/database"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for root in "$staging_root" "$hml_root" "$prd_root"; do
  for file in main.tf variables.tf outputs.tf versions.tf; do
    [[ -f "$root/$file" ]] || fail "missing root Terraform file: ${root#"$repo_root"/}/$file"
  done
  grep -Fq 'required_version = ">= 1.10.0, < 2.0.0"' "$root/versions.tf" \
    || fail "Terraform version range is missing from ${root#"$repo_root"/}"
  rg -q 'version[[:space:]]*=[[:space:]]*"~> 6\.70"' "$root/versions.tf" \
    || fail "AWS provider version constraint is missing from ${root#"$repo_root"/}"
  grep -Fq 'bucket       = "auto-shop-tfstate-035611741563-use1"' "$root/versions.tf" \
    || fail "state bucket contract changed in ${root#"$repo_root"/}"
  grep -Fq 'use_lockfile = true' "$root/versions.tf" \
    || fail "S3 native state locking is missing from ${root#"$repo_root"/}"
done
for root in "$staging_root" "$hml_root" "$prd_root"; do
  grep -Fq 'prefix = "/auto-shop/staging"' "$root/main.tf" \
    || fail "SSM contract prefix changed in ${root#"$repo_root"/}"
done

[[ ! -d "$repo_root/envs/production" ]] || fail 'production RDS Terraform root is prohibited'
grep -Fq 'key          = "database-infra/staging/terraform.tfstate"' "$staging_root/versions.tf" \
  || fail 'shared database state key changed'
grep -Fq 'key          = "database-infra/hml/terraform.tfstate"' "$hml_root/versions.tf" \
  || fail 'HML state key changed'
grep -Fq 'key          = "database-infra/prd/terraform.tfstate"' "$prd_root/versions.tf" \
  || fail 'PRD state key changed'

rg -q 'isolated_subnet_ids[[:space:]]*=[[:space:]]*nonsensitive\(' "$staging_root/main.tf" \
  || fail 'validated non-secret subnet IDs must be explicitly declassified before module use'
for resource in \
  'module "network"' \
  'module "instance"' \
  'resource "aws_iam_role" "db_bootstrap"' \
  'resource "aws_iam_role_policy" "db_bootstrap"' \
  'resource "aws_eks_pod_identity_association" "db_bootstrap"'; do
  grep -Fq "$resource" "$staging_root/main.tf" || fail "shared root is missing $resource"
done
grep -Fq 'permissions_boundary = local.boundary_arn' "$staging_root/main.tf" \
  || fail 'bootstrap role permissions boundary is missing'
grep -Fq '"pods.eks.amazonaws.com"' "$staging_root/main.tf" \
  || fail 'Pod Identity trust principal is missing'
grep -Fq 'variable = "aws:SourceArn"' "$staging_root/main.tf" \
  || fail 'Pod Identity source ARN condition is missing'
grep -Fq 'variable = "aws:SourceAccount"' "$staging_root/main.tf" \
  || fail 'Pod Identity source account condition is missing'

for parameter in \
  /auto-shop/staging/network/vpc-id \
  /auto-shop/staging/network/rds-isolated-subnet-ids \
  /auto-shop/staging/network/eks-node-security-group-id \
  /auto-shop/staging/network/lambda-security-group-id \
  /auto-shop/staging/eks/cluster-name; do
  grep -Fq "$parameter" "$staging_root/main.tf" || fail "missing upstream SSM contract parameter: $parameter"
done
for parameter in database/host database/port database/security-group-id database/secrets/owner-arn; do
  grep -Fq "\"$parameter\"" "$staging_root/main.tf" || fail "missing shared SSM key: $parameter"
done

# Issue #5's stable output contract must be declared by the single root that
# owns each parameter and documented for consumers.
required_ssm_paths=(
  /auto-shop/staging/database/host
  /auto-shop/staging/database/port
  /auto-shop/staging/database/security-group-id
  /auto-shop/staging/database/names/hml
  /auto-shop/staging/database/names/prd
  /auto-shop/staging/database/secrets/runtime-hml-arn
  /auto-shop/staging/database/secrets/runtime-prd-arn
  /auto-shop/staging/database/secrets/lambda-hml-arn
  /auto-shop/staging/database/secrets/lambda-prd-arn
  /auto-shop/staging/database/secrets/migrations-hml-arn
  /auto-shop/staging/database/secrets/migrations-prd-arn
  /auto-shop/staging/database/secrets/owner-arn
  /auto-shop/staging/database/iam/lambda-read-policy-arn/hml
  /auto-shop/staging/database/iam/lambda-read-policy-arn/prd
  /auto-shop/staging/database/iam/migrations-hml-read-policy-arn
  /auto-shop/staging/database/iam/migrations-prd-read-policy-arn
)
[[ "${#required_ssm_paths[@]}" -eq 16 ]] || fail 'the closed database SSM contract must contain exactly 16 names'
for parameter in "${required_ssm_paths[@]}"; do
  grep -Fq "$parameter" "$repo_root/README.md" \
    || fail "README does not document the issue #5 SSM contract path: $parameter"
done
grep -Fq 'elas não são parâmetros SSM' "$repo_root/README.md" \
  || fail 'README must state that bootstrap role ARNs are excluded from the SSM contract'
for consumer_contract in \
  'ESO HML:' \
  'ESO PRD:' \
  'Job de migrations HML' \
  'Job de migrations PRD' \
  'somente o Job de bootstrap deste repositório' \
  'role da função `lambda-auth` hml' \
  'role da função `lambda-auth` prd'; do
  grep -Fq "$consumer_contract" "$repo_root/README.md" \
    || fail "README omitted the database SSM consumer mapping: $consumer_contract"
done

expected_ssm_keys=(
  database/host
  database/port
  database/security-group-id
  database/secrets/owner-arn
  database/names/hml
  database/secrets/runtime-hml-arn
  database/secrets/lambda-hml-arn
  database/secrets/migrations-hml-arn
  database/iam/lambda-read-policy-arn/hml
  database/iam/migrations-hml-read-policy-arn
  database/names/prd
  database/secrets/runtime-prd-arn
  database/secrets/lambda-prd-arn
  database/secrets/migrations-prd-arn
  database/iam/lambda-read-policy-arn/prd
  database/iam/migrations-prd-read-policy-arn
)
actual_ssm_keys="$(
  rg -o --no-filename '"database/[^"]+"' "$staging_root/main.tf" "$hml_root/main.tf" "$prd_root/main.tf" \
    | tr -d '"' \
    | sort -u
)"
expected_ssm_keys_sorted="$(printf '%s\n' "${expected_ssm_keys[@]}" | sort -u)"
[[ "$actual_ssm_keys" == "$expected_ssm_keys_sorted" ]] \
  || fail 'the Terraform roots must publish exactly the 16 approved SSM keys'

for output_name in db_host db_port db_security_group_id db_names runtime_secret_arns lambda_secret_arns owner_secret_arn ssm_parameters; do
  grep -Fq "output \"$output_name\"" "$staging_root/outputs.tf" \
    || fail "shared outputs are missing issue #5 contract value: $output_name"
done
for environment in hml prd; do
  root="$repo_root/envs/$environment/database"
  for output_name in environment db_name runtime_secret_arn lambda_secret_arn ssm_parameters; do
    grep -Fq "output \"$output_name\"" "$root/outputs.tf" \
      || fail "$environment outputs are missing issue #5 contract value: $output_name"
  done
done

for environment in hml prd; do
  if [[ "$environment" == hml ]]; then
    root="$hml_root"
    other_environment=prd
  else
    root="$prd_root"
    other_environment=hml
  fi

  grep -Fq "environment = \"$environment\"" "$root/main.tf" \
    || fail "${environment} root must declare only its logical environment"
  grep -Fq 'environments = [local.environment]' "$root/main.tf" \
    || fail "${environment} root must create only its own secret metadata"
  for policy in \
    "lambda_${environment}_secret_read" \
    "migration_${environment}_secret_read" \
    "bootstrap_${environment}_secret_access"; do
    grep -Fq "resource \"aws_iam_policy\" \"$policy\"" "$root/main.tf" \
      || fail "${environment} root is missing its $policy policy"
  done
  grep -Fq "resource \"aws_iam_role_policy_attachment\" \"bootstrap_${environment}_secret_access\"" "$root/main.tf" \
    || fail "${environment} bootstrap policy is not attached to its environment role"
  grep -Fq 'resource "aws_iam_role" "environment_bootstrap"' "$root/main.tf" \
    || fail "${environment} root is missing its environment-specific bootstrap role"
  grep -Fq 'name                 = "auto-shop-staging-db-bootstrap-${local.environment}"' "$root/main.tf" \
    || fail "${environment} bootstrap role name does not match the K8s Pod Identity contract"
  grep -Fq 'variable = "aws:RequestTag/kubernetes-namespace"' "$root/main.tf" \
    || fail "${environment} bootstrap trust is not limited to the operations namespace"
  grep -Fq 'values   = ["auto-shop-db-bootstrap-${local.environment}"]' "$root/main.tf" \
    || fail "${environment} bootstrap trust does not match its environment service account"
  grep -Fq 'role       = aws_iam_role.environment_bootstrap.name' "$root/main.tf" \
    || fail "${environment} bootstrap secret policy is not attached to its isolated role"
  grep -Fq 'module.secrets.runtime_secret_arns[local.environment]' "$root/main.tf" \
    || fail "${environment} bootstrap role policy is not scoped to its own runtime secret"
  grep -Fq 'module.secrets.lambda_secret_arns[local.environment]' "$root/main.tf" \
    || fail "${environment} bootstrap role policy is not scoped to its own Lambda secret"
  grep -Fq 'module.secrets.migration_secret_arns[local.environment]' "$root/main.tf" \
    || fail "${environment} bootstrap role policy is not scoped to its own migration secret"
  for parameter in \
    "database/names/$environment" \
    "database/secrets/runtime-$environment-arn" \
    "database/secrets/lambda-$environment-arn" \
    "database/secrets/migrations-$environment-arn" \
    "database/iam/lambda-read-policy-arn/$environment" \
    "database/iam/migrations-$environment-read-policy-arn"; do
    grep -Fq "\"$parameter\"" "$root/main.tf" || fail "${environment} root is missing SSM key: $parameter"
  done
  if rg -n '^resource "aws_(db_instance|db_subnet_group|security_group|eks_pod_identity_association)"' "$root"; then
    fail "${environment} root contains shared database, network, or Pod Identity resources"
  fi
  if rg -n "\"$other_environment\"|database/(names|secrets|iam)/[^\"]*$other_environment" "$root/main.tf"; then
    fail "${environment} root contains explicit references to the other environment"
  fi
done

for contract in \
  'auto-shop-staging-db-bootstrap-hml' \
  'auto-shop-ops/auto-shop-db-bootstrap-hml' \
  'auto-shop-staging-db-bootstrap-prd' \
  'auto-shop-ops/auto-shop-db-bootstrap-prd'; do
  grep -Fq "$contract" "$repo_root/.github/database-delivery.md" \
    || fail "database delivery docs omitted the DB/K8s bootstrap handshake value: $contract"
done
grep -Fq 'derived by the bootstrap runner' "$repo_root/.github/database-delivery.md" \
  || fail 'database delivery docs must state that the bootstrap role ARN is derived, not published to SSM'

if rg -n -g '!**/tests/**' 'aws_db_proxy|terraform_remote_state|aws_secretsmanager_secret_version|random_password|SecureString' "$repo_root/envs" "$repo_root/modules"; then
  fail 'Terraform contains a resource or value prohibited by the database contract'
fi
if rg -n -g '!**/tests/**' 'DATABASE_URL' "$repo_root/envs" "$repo_root/modules"; then
  fail 'Terraform must not store application connection strings'
fi

for output_name in db_host db_port db_security_group_id db_names runtime_secret_arns lambda_secret_arns owner_secret_arn bootstrap_role_arn ssm_parameters; do
  grep -Fq "output \"$output_name\"" "$staging_root/outputs.tf" || fail "shared root output is missing: $output_name"
done
grep -Fq '/auto-shop/staging/database/iam/owner-read-policy-arn' "$repo_root/scripts/orphans.sh" \
  || fail 'orphan scan must continue checking that the removed owner-read SSM contract stays absent'
for environment in hml prd; do
  root="$repo_root/envs/$environment/database"
  for output_name in environment db_name runtime_secret_arn lambda_secret_arn migration_secret_arn lambda_read_policy_arn migration_read_policy_arn bootstrap_secret_access_policy_arn bootstrap_role_arn ssm_parameters; do
    grep -Fq "output \"$output_name\"" "$root/outputs.tf" || fail "$environment root output is missing: $output_name"
  done
done

if rg -n 'sensitive[[:space:]]*=[[:space:]]*true|value[[:space:]]*=.*postgres(ql)?://|value[[:space:]]*=.*password' "$staging_root/outputs.tf" "$hml_root/outputs.tf" "$prd_root/outputs.tf"; then
  fail 'root outputs must not contain a sensitive value or connection string'
fi

printf 'PASS: shared staging and isolated HML/PRD root contracts match the plan\n'
