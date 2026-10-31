mock_provider "aws" {}

run "prd_root_owns_only_prd_database_metadata" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_data {
    target = data.aws_ssm_parameter.cluster_name
    values = { value = "auto-shop-staging" }
  }

  override_data {
    target = data.aws_ssm_parameter.owner_secret_arn
    values = { value = "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-test-abc123" }
  }

  override_data {
    target = data.aws_iam_policy_document.environment_bootstrap_trust
    values = {
      json = <<-JSON
        {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"],"Condition":{"StringEquals":{"aws:RequestTag/kubernetes-namespace":"auto-shop-ops","aws:RequestTag/kubernetes-service-account":"auto-shop-db-bootstrap-prd"}}}]}
      JSON
    }
  }

  override_resource {
    target          = module.secrets.aws_secretsmanager_secret.runtime["prd"]
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/app-runtime-abc123" }
  }

  override_resource {
    target          = module.secrets.aws_secretsmanager_secret.lambda["prd"]
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/lambda-auth-abc123" }
  }

  override_resource {
    target          = module.secrets.aws_secretsmanager_secret.migrations["prd"]
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/migrations-abc123" }
  }

  override_data {
    target = data.aws_iam_policy_document.lambda_prd_secret_read
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.migration_prd_secret_read
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.bootstrap_prd_secret_access
    values = {
      json = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue"]
          Resource = [
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/app-runtime-abc123",
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/lambda-auth-abc123",
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/prd/migrations-abc123",
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-test-abc123",
          ]
        }]
      })
    }
  }

  assert {
    condition = (
      local.environment == "prd" && local.db_name == "autoshop_prd" &&
      local.tags.Environment == "prd" && aws_iam_policy.lambda_prd_secret_read.tags.Environment == "prd"
    )
    error_message = "The PRD root and its IAM policies must carry PRD identity and tags."
  }

  assert {
    condition = (
      aws_iam_role.environment_bootstrap.name == "auto-shop-staging-db-bootstrap-prd" &&
      strcontains(aws_iam_role.environment_bootstrap.assume_role_policy, "auto-shop-db-bootstrap-prd") &&
      aws_iam_role_policy_attachment.bootstrap_prd_secret_access.role == aws_iam_role.environment_bootstrap.name
    )
    error_message = "The PRD bootstrap role and Pod Identity service-account contract must be PRD-specific."
  }

  assert {
    condition = sort(jsondecode(aws_iam_policy.bootstrap_prd_secret_access.policy).Statement[0].Resource) == sort([
      module.secrets.runtime_secret_arns["prd"],
      module.secrets.lambda_secret_arns["prd"],
      module.secrets.migration_secret_arns["prd"],
      "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-test-abc123",
    ])
    error_message = "The PRD bootstrap policy may access only PRD credentials and the shared RDS owner secret."
  }

  assert {
    condition = (
      length(module.secrets.runtime_secret_arns) == 1 &&
      keys(module.secrets.runtime_secret_arns) == ["prd"] &&
      length(module.secrets.lambda_secret_arns) == 1 && keys(module.secrets.lambda_secret_arns) == ["prd"] &&
      length(module.secrets.migration_secret_arns) == 1 && keys(module.secrets.migration_secret_arns) == ["prd"]
    )
    error_message = "The PRD root must create metadata for PRD secrets only."
  }

  assert {
    condition = sort(module.ssm_contract.parameter_names) == sort([
      "/auto-shop/staging/database/names/prd",
      "/auto-shop/staging/database/secrets/runtime-prd-arn",
      "/auto-shop/staging/database/secrets/lambda-prd-arn",
      "/auto-shop/staging/database/secrets/migrations-prd-arn",
      "/auto-shop/staging/database/iam/migrations-prd-read-policy-arn",
      "/auto-shop/staging/database/iam/lambda-read-policy-arn/prd",
    ])
    error_message = "The PRD root must publish only PRD-specific database metadata to SSM."
  }
}
