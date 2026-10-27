output "subnet_group_name" {
  description = "RDS subnet group name."
  value       = aws_db_subnet_group.this.name
}

output "security_group_id" {
  description = "RDS security group ID."
  value       = aws_security_group.this.id
}
