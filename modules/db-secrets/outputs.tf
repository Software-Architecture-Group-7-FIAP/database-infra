output "runtime_secret_arns" {
  description = "Secret metadata ARNs for External Secrets runtime credentials."
  value       = { for environment, secret in aws_secretsmanager_secret.runtime : environment => secret.arn }
}

output "lambda_secret_arns" {
  description = "Secret metadata ARNs for Lambda read-only credentials."
  value       = { for environment, secret in aws_secretsmanager_secret.lambda : environment => secret.arn }
}

output "migration_secret_arns" {
  description = "Secret metadata ARNs for environment-scoped database migration credentials."
  value       = { for environment, secret in aws_secretsmanager_secret.migrations : environment => secret.arn }
}
