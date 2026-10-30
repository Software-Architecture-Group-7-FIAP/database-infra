#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$repo_root/envs/staging/database"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for file in main.tf variables.tf outputs.tf versions.tf; do
  [[ -f "$root/$file" ]] || fail "missing root Terraform file: $file"
done

[[ ! -d "$repo_root/envs/production" ]] || fail 'production Terraform root is prohibited'

grep -Fq 'required_version = ">= 1.10.0, < 2.0.0"' "$root/versions.tf" || fail 'root Terraform version range is missing'
rg -q 'version[[:space:]]*=[[:space:]]*"~> 6\.70"' "$root/versions.tf" || fail 'AWS provider version constraint is missing'
grep -Fq 'bucket       = "auto-shop-tfstate-035611741563-use1"' "$root/versions.tf" || fail 'state bucket contract changed'
grep -Fq 'key          = "database-infra/staging/terraform.tfstate"' "$root/versions.tf" || fail 'state key contract changed'
grep -Fq 'use_lockfile = true' "$root/versions.tf" || fail 'S3 native state locking is missing'
rg -q 'isolated_subnet_ids[[:space:]]*=[[:space:]]*nonsensitive\(' "$root/main.tf" || fail 'validated non-secret subnet IDs must be explicitly declassified before module for_each'

role_count="$(grep -Ec '^resource "aws_iam_role"' "$root/main.tf")"
[[ "$role_count" -eq 1 ]] || fail 'the database root must create exactly one IAM role'
policy_count="$(grep -Ec '^resource "aws_iam_policy"' "$root/main.tf")"
[[ "$policy_count" -eq 4 ]] || fail 'the database root must create four isolated consumer policies'
for policy in migration_hml_secret_read migration_prd_secret_read lambda_hml_secret_read lambda_prd_secret_read; do
  grep -Fq "resource \"aws_iam_policy\" \"$policy\"" "$root/main.tf" || fail "the $policy consumer policy is missing"
done
grep -Fq 'permissions_boundary = local.boundary_arn' "$root/main.tf" || fail 'bootstrap role permissions boundary is missing'
grep -Fq '"pods.eks.amazonaws.com"' "$root/main.tf" || fail 'Pod Identity trust principal is missing'
grep -Fq 'variable = "aws:SourceArn"' "$root/main.tf" || fail 'Pod Identity source ARN condition is missing'
grep -Fq 'variable = "aws:SourceAccount"' "$root/main.tf" || fail 'Pod Identity source account condition is missing'

for parameter in \
  /auto-shop/staging/network/vpc-id \
  /auto-shop/staging/network/rds-isolated-subnet-ids \
  /auto-shop/staging/network/eks-node-security-group-id \
  /auto-shop/staging/network/lambda-security-group-id \
  /auto-shop/staging/eks/cluster-name; do
  grep -Fq "$parameter" "$root/main.tf" || fail "missing upstream SSM contract parameter: $parameter"
done

expected_ssm_keys=(
  database/host
  database/port
  database/security-group-id
  database/names/hml
  database/names/prd
  database/secrets/runtime-hml-arn
  database/secrets/runtime-prd-arn
  database/secrets/lambda-hml-arn
  database/secrets/lambda-prd-arn
  database/secrets/migrations-hml-arn
  database/secrets/migrations-prd-arn
  database/secrets/owner-arn
  database/iam/lambda-read-policy-arn/hml
  database/iam/lambda-read-policy-arn/prd
  database/iam/migrations-hml-read-policy-arn
  database/iam/migrations-prd-read-policy-arn
)
ssm_contract_block="$(sed -n '/^module "ssm_contract" {/,/^}/p' "$root/main.tf")"
published_ssm_keys="$(printf '%s\n' "$ssm_contract_block" | rg -o '"database/[^"]+"' | tr -d '"' | sort)"
expected_ssm_keys_sorted="$(printf '%s\n' "${expected_ssm_keys[@]}" | sort)"
[[ "$published_ssm_keys" == "$expected_ssm_keys_sorted" ]] || fail 'published SSM contract keys differ from the exact 16-key contract'
if grep -Fq '"database/iam/owner-read-policy-arn"' <<< "$ssm_contract_block"; then
  fail 'legacy database/iam/owner-read-policy-arn must not be published'
fi

for consumer_contract in \
  'ESO HML: `auto-shop/staging/hml/app-runtime`' \
  'ESO PRD: `auto-shop/staging/prd/app-runtime`' \
  'Job de migrations HML do `auto-shop-system`: consome `/auto-shop/staging/database/secrets/migrations-hml-arn` e `/auto-shop/staging/database/iam/migrations-hml-read-policy-arn`; o repositorio possui a role, ServiceAccount e associacao Pod Identity por ambiente.' \
  'Job de migrations PRD do `auto-shop-system`: consome `/auto-shop/staging/database/secrets/migrations-prd-arn` e `/auto-shop/staging/database/iam/migrations-prd-read-policy-arn`; o repositorio possui a role, ServiceAccount e associacao Pod Identity por ambiente.' \
  '`k8s-infra` provisiona EKS e namespaces e pode possuir a ServiceAccount de bootstrap do banco; nao possui as identidades de migrations da aplicacao.'; do
  grep -Fq "$consumer_contract" "$repo_root/README.md" || fail "missing or incorrect downstream consumer mapping: $consumer_contract"
done

if rg -n -g '!**/tests/**' 'aws_db_proxy|terraform_remote_state|aws_secretsmanager_secret_version|random_password|SecureString' "$repo_root/envs" "$repo_root/modules"; then
  fail 'Terraform contains a resource or value prohibited by the database contract'
fi
if rg -n -g '!**/tests/**' 'DATABASE_URL' "$repo_root/envs" "$repo_root/modules"; then
  fail 'Terraform must not store application connection strings'
fi

for output_name in db_host db_port db_security_group_id db_names runtime_secret_arns lambda_secret_arns owner_secret_arn bootstrap_role_arn ssm_parameters; do
  grep -Fq "output \"$output_name\"" "$root/outputs.tf" || fail "missing root output: $output_name"
done

if rg -n 'sensitive[[:space:]]*=[[:space:]]*true|value[[:space:]]*=.*postgres(ql)?://|value[[:space:]]*=.*password' "$root/outputs.tf"; then
  fail 'root outputs must not contain a sensitive value or connection string'
fi

printf 'PASS: single staging root and published database contract match the plan\n'
