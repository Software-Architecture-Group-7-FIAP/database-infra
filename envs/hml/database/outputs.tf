output "environment" {
  description = "Logical environment owned by this state."
  value       = "hml"
}

output "db_name" {
  description = "Logical HML database name on the one shared staging RDS instance."
  value       = local.db_name
}

output "runtime_secret_arn" {
  description = "HML runtime secret metadata ARN; the secret value is never read by Terraform."
  value       = module.secrets.runtime_secret_arns[local.environment]
}

output "lambda_secret_arn" {
  description = "HML Lambda secret metadata ARN; the secret value is never read by Terraform."
  value       = module.secrets.lambda_secret_arns[local.environment]
}

output "migration_secret_arn" {
  description = "HML migration secret metadata ARN; the secret value is never read by Terraform."
  value       = module.secrets.migration_secret_arns[local.environment]
}

output "lambda_read_policy_arn" {
  description = "HML Lambda policy ARN scoped to the HML Lambda secret."
  value       = aws_iam_policy.lambda_hml_secret_read.arn
}

output "migration_read_policy_arn" {
  description = "HML migration policy ARN scoped to the HML migration secret."
  value       = aws_iam_policy.migration_hml_secret_read.arn
}

output "bootstrap_secret_access_policy_arn" {
  description = "Policy attached to the HML-only bootstrap role; includes only HML credentials plus the shared RDS owner secret."
  value       = aws_iam_policy.bootstrap_hml_secret_access.arn
}

output "bootstrap_role_arn" {
  description = "HML-only bootstrap role ARN published for the matching Kubernetes Pod Identity association."
  value       = aws_iam_role.environment_bootstrap.arn
}

output "ssm_parameters" {
  description = "Environment-specific non-secret parameter names in the shared staging namespace."
  value       = module.ssm_contract.parameter_names
}
