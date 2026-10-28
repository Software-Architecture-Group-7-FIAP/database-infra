resource "aws_secretsmanager_secret" "runtime" {
  #checkov:skip=CKV_AWS_149:Staging uses the AWS-managed aws/secretsmanager KMS key; a customer-managed key adds monthly cost without a separate access requirement.
  for_each = toset(var.environments)

  name                    = "${var.prefix}/${each.value}/app-runtime"
  description             = "Application runtime credential metadata for the ${each.value} logical database."
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "lambda" {
  #checkov:skip=CKV_AWS_149:Staging uses the AWS-managed aws/secretsmanager KMS key; a customer-managed key adds monthly cost without a separate access requirement.
  for_each = toset(var.environments)

  name                    = "${var.prefix}/${each.value}/lambda-auth"
  description             = "Read-only Lambda credential metadata for the ${each.value} logical database."
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "migrations" {
  #checkov:skip=CKV_AWS_149:Staging uses the AWS-managed aws/secretsmanager KMS key and keeps no customer-managed key state.
  for_each = toset(var.environments)

  name                    = "${var.prefix}/${each.value}/migrations"
  description             = "Database-scoped migration credential metadata for ${each.value}."
  recovery_window_in_days = 0
  tags                    = var.tags
}
