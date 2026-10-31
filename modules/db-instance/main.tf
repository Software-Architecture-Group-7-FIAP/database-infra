resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-postgres16"
  family      = "postgres16"
  description = "TLS enforcement and slow-query logging for ${var.name}."
  tags        = var.tags

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_161:Application and Lambda roles authenticate with per-environment SCRAM secrets, not IAM tokens.
  #checkov:skip=CKV_AWS_129:PostgreSQL query logs can contain application data; CloudWatch export is disabled to limit exposure and ingestion.
  #checkov:skip=CKV_AWS_211:rds-ca-rsa2048-g1 is a current G1 CA with automatic rotation; Checkov 2.0.930 does not recognize this identifier.
  #checkov:skip=CKV_AWS_157:Single-AZ is an approved staging cost constraint; production availability is a separate decision.
  #checkov:skip=CKV_AWS_118:Enhanced Monitoring is disabled for cost control on ephemeral staging; standard RDS metrics remain available.
  identifier = var.name

  engine         = "postgres"
  engine_version = "16.15"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 0
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = null
  username = "autoshop_owner"

  manage_master_user_password = true

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  parameter_group_name = aws_db_parameter_group.this.name
  ca_cert_identifier   = "rds-ca-rsa2048-g1"

  backup_retention_period  = var.backup_retention_period
  backup_window            = var.backup_window
  maintenance_window       = "Sun:07:00-Sun:07:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false

  apply_immediately               = true
  auto_minor_version_upgrade      = true
  allow_major_version_upgrade     = false
  monitoring_interval             = 0
  performance_insights_enabled    = false
  enabled_cloudwatch_logs_exports = []

  tags = var.tags

  lifecycle {
    prevent_destroy = false
  }

  timeouts {
    delete = "18m"
  }
}
