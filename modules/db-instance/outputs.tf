output "address" {
  description = "RDS endpoint hostname."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "identifier" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master secret; its value is never read by Terraform."
  value       = one(aws_db_instance.this.master_user_secret).secret_arn
}

output "resource_id" {
  description = "RDS resource identifier used for scoped IAM policies."
  value       = aws_db_instance.this.resource_id
}
