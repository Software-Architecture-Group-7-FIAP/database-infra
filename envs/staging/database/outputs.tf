output "db_host" {
  description = "Private PostgreSQL endpoint hostname."
  value       = module.instance.address
}

output "db_port" {
  description = "PostgreSQL port."
  value       = module.instance.port
}

output "db_security_group_id" {
  description = "RDS security group ID."
  value       = module.network.security_group_id
}

output "db_names" {
  description = "Logical hml and prd database names on the shared staging instance."
  value       = local.db_names
}

output "runtime_secret_arns" {
  description = "Secret metadata ARNs for hml and prd application runtime credentials."
  value       = local.runtime_secret_arns
}

output "lambda_secret_arns" {
  description = "Secret metadata ARNs for hml and prd Lambda credentials."
  value       = local.lambda_secret_arns
}

output "owner_secret_arn" {
  description = "RDS-managed master secret ARN; the secret value is not read by Terraform."
  value       = module.instance.master_user_secret_arn
}

output "bootstrap_role_arn" {
  description = "Pod Identity role ARN used only by the database bootstrap Job."
  value       = aws_iam_role.db_bootstrap.arn
}

output "ssm_parameters" {
  description = "Published non-secret parameter names in the staging database contract."
  value       = module.ssm_contract.parameter_names
}
