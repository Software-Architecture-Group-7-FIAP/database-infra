mock_provider "aws" {}

run "hml_root_owns_only_hml_database_metadata" {
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
        {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"],"Condition":{"StringEquals":{"aws:RequestTag/kubernetes-namespace":"auto-shop-ops","aws:RequestTag/kubernetes-service-account":"auto-shop-db-bootstrap-hml"}}}]}
      JSON
    }
  }

  override_resource {
    target          = module.secrets.aws_secretsmanager_secret.runtime["hml"]
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/app-runtime-abc123" }
  }

  override_resource {
    target          = module.secrets.aws_secretsmanager_secret.lambda["hml"]
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/lambda-auth-abc123" }
  }

  override_resource {
    target          = module.secrets.aws_secretsmanager_secret.migrations["hml"]
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/migrations-abc123" }
  }

  override_data {
    target = data.aws_iam_policy_document.lambda_hml_secret_read
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.migration_hml_secret_read
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.bootstrap_hml_secret_access
    values = {
      json = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue"]
          Resource = [
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/app-runtime-abc123",
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/lambda-auth-abc123",
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:auto-shop/staging/hml/migrations-abc123",
            "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-test-abc123",
          ]
        }]
      })
    }
  }

  assert {
    condition = (
      local.environment == "hml" && local.db_name == "autoshop_hml" &&
      local.tags.Environment == "hml" && aws_iam_policy.lambda_hml_secret_read.tags.Environment == "hml"
    )
    error_message = "The HML root and its IAM policies must carry HML identity and tags."
  }

  assert {
    condition = (
      aws_iam_role.environment_bootstrap.name == "auto-shop-staging-db-bootstrap-hml" &&
      strcontains(aws_iam_role.environment_bootstrap.assume_role_policy, "auto-shop-db-bootstrap-hml") &&
      aws_iam_role_policy_attachment.bootstrap_hml_secret_access.role == aws_iam_role.environment_bootstrap.name
    )
    error_message = "The HML bootstrap role and Pod Identity service-account contract must be HML-specific."
  }

  assert {
    condition = sort(jsondecode(aws_iam_policy.bootstrap_hml_secret_access.policy).Statement[0].Resource) == sort([
      module.secrets.runtime_secret_arns["hml"],
      module.secrets.lambda_secret_arns["hml"],
      module.secrets.migration_secret_arns["hml"],
      "arn:aws:secretsmanager:us-east-1:035611741563:secret:rds!db-test-abc123",
    ])
    error_message = "The HML bootstrap policy may access only HML credentials and the shared RDS owner secret."
  }

  assert {
    condition = (
      length(module.secrets.runtime_secret_arns) == 1 &&
      keys(module.secrets.runtime_secret_arns) == ["hml"] &&
      length(module.secrets.lambda_secret_arns) == 1 && keys(module.secrets.lambda_secret_arns) == ["hml"] &&
      length(module.secrets.migration_secret_arns) == 1 && keys(module.secrets.migration_secret_arns) == ["hml"]
    )
    error_message = "The HML root must create metadata for HML secrets only."
  }

  assert {
    condition = sort(module.ssm_contract.parameter_names) == sort([
      "/auto-shop/staging/database/names/hml",
      "/auto-shop/staging/database/secrets/runtime-hml-arn",
      "/auto-shop/staging/database/secrets/lambda-hml-arn",
      "/auto-shop/staging/database/secrets/migrations-hml-arn",
      "/auto-shop/staging/database/iam/migrations-hml-read-policy-arn",
      "/auto-shop/staging/database/iam/lambda-read-policy-arn/hml",
      "/auto-shop/staging/database/iam/bootstrap-role-arn/hml",
    ])
    error_message = "The HML root must publish only HML-specific database metadata to SSM."
  }
}
