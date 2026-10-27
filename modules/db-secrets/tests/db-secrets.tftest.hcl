mock_provider "aws" {}

variables {
  prefix       = "auto-shop/staging"
  environments = ["hml", "prd"]
  tags         = { Project = "auto-shop", Environment = "staging" }
}

run "creates_only_runtime_and_lambda_secret_metadata" {
  command = plan

  assert {
    condition     = length(aws_secretsmanager_secret.runtime) == 2
    error_message = "The module must create one app-runtime secret for each logical database."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.lambda) == 2
    error_message = "The module must create one lambda-auth secret for each logical database."
  }

  assert {
    condition     = aws_secretsmanager_secret.runtime["hml"].name == "auto-shop/staging/hml/app-runtime"
    error_message = "The hml runtime name is part of the External Secrets contract."
  }

  assert {
    condition     = aws_secretsmanager_secret.runtime["prd"].name == "auto-shop/staging/prd/app-runtime"
    error_message = "The prd runtime name is part of the External Secrets contract."
  }

  assert {
    condition = alltrue(concat(
      [for secret in values(aws_secretsmanager_secret.runtime) : secret.recovery_window_in_days == 0 && secret.kms_key_id == null],
      [for secret in values(aws_secretsmanager_secret.lambda) : secret.recovery_window_in_days == 0 && secret.kms_key_id == null]
    ))
    error_message = "Ephemeral secrets must use immediate deletion and the AWS managed Secrets Manager key."
  }
}

run "rejects_prefix_outside_the_contract" {
  command = plan

  variables {
    prefix = "other-project/staging"
  }

  expect_failures = [var.prefix]
}

run "rejects_unexpected_environment_names" {
  command = plan

  variables {
    environments = ["staging", "production"]
  }

  expect_failures = [var.environments]
}
