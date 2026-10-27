mock_provider "aws" {
  mock_resource "aws_db_instance" {
    defaults = {
      address     = "auto-shop-staging.mock.invalid"
      port        = 5432
      resource_id = "db-MOCK1234567890"
      password    = null
      kms_key_id  = null
      master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-MOCK1234567890"
      }]
    }
  }
}

variables {
  name                    = "auto-shop-staging"
  db_subnet_group_name    = "auto-shop-staging-subnets"
  security_group_id       = "sg-12345678"
  backup_window           = "01:00-01:30"
  backup_retention_period = 1
  multi_az                = false
  tags                    = { Project = "auto-shop", Environment = "staging" }
}

run "creates_an_ephemeral_private_postgres_instance" {
  command = apply

  assert {
    condition = (
      aws_db_instance.this.engine == "postgres" &&
      aws_db_instance.this.engine_version == "16.15" &&
      aws_db_instance.this.instance_class == "db.t4g.micro"
    )
    error_message = "The RDS engine, minor version, and class must match the approved staging plan."
  }

  assert {
    condition = (
      aws_db_instance.this.allocated_storage == 20 &&
      aws_db_instance.this.storage_type == "gp3" &&
      aws_db_instance.this.max_allocated_storage == 0 &&
      aws_db_instance.this.storage_encrypted
    )
    error_message = "RDS storage must be encrypted gp3 with 20 GiB and no autoscaling."
  }

  assert {
    condition = (
      !aws_db_instance.this.publicly_accessible &&
      !aws_db_instance.this.multi_az &&
      !aws_db_instance.this.deletion_protection &&
      aws_db_instance.this.skip_final_snapshot &&
      aws_db_instance.this.delete_automated_backups &&
      aws_db_instance.this.backup_retention_period == 1
    )
    error_message = "The RDS instance must stay private and tear down with its automated backups."
  }

  assert {
    condition = (
      aws_db_instance.this.manage_master_user_password &&
      aws_db_instance.this.username == "autoshop_owner" &&
      aws_db_instance.this.password == null &&
      aws_db_instance.this.kms_key_id == null
    )
    error_message = "RDS must manage its master password and use the AWS managed storage key."
  }

  assert {
    condition = anytrue([
      for parameter in aws_db_parameter_group.this.parameter :
      parameter.name == "rds.force_ssl" && parameter.value == "1"
      ]) && anytrue([
      for parameter in aws_db_parameter_group.this.parameter :
      parameter.name == "log_min_duration_statement" && parameter.value == "1000"
    ])
    error_message = "The parameter group must enforce TLS and log slow statements."
  }

  assert {
    condition = (
      output.address == "auto-shop-staging.mock.invalid" &&
      output.port == 5432 &&
      output.master_user_secret_arn == "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-MOCK1234567890" &&
      output.resource_id == "db-MOCK1234567890"
    )
    error_message = "The module must expose endpoint metadata and only the RDS managed-secret ARN."
  }
}

run "rejects_backup_retention_above_one_day" {
  command = plan

  variables {
    backup_retention_period = 2
  }

  expect_failures = [var.backup_retention_period]
}

run "rejects_multi_az" {
  command = plan

  variables {
    multi_az = true
  }

  expect_failures = [var.multi_az]
}
