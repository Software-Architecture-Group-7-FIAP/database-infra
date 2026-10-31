provider "aws" {
  region              = var.aws_region
  allowed_account_ids = ["035611741563"]
}

locals {
  environment = "hml"
  account_id  = "035611741563"
  tags = {
    Project     = "auto-shop"
    Repository  = "database-infra"
    Environment = "hml"
    ManagedBy   = "Terraform"
  }
  db_name = "autoshop_${local.environment}"
}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "cluster_name" {
  name = "/auto-shop/staging/eks/cluster-name"
}

data "aws_ssm_parameter" "owner_secret_arn" {
  name = "/auto-shop/staging/database/secrets/owner-arn"
}

module "secrets" {
  source = "../../../modules/db-secrets"

  prefix       = "auto-shop/staging"
  environments = [local.environment]
  tags         = local.tags
}

data "aws_iam_policy_document" "lambda_hml_secret_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.secrets.lambda_secret_arns[local.environment]]
  }
}

resource "aws_iam_policy" "lambda_hml_secret_read" {
  name        = "auto-shop-staging-db-read-lambda-hml"
  path        = "/auto-shop/"
  description = "Read only the staging hml Lambda credential secret."
  policy      = data.aws_iam_policy_document.lambda_hml_secret_read.json
  tags        = local.tags
}

data "aws_iam_policy_document" "migration_hml_secret_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.secrets.migration_secret_arns[local.environment]]
  }
}

resource "aws_iam_policy" "migration_hml_secret_read" {
  name        = "auto-shop-staging-db-read-migrations-hml"
  path        = "/auto-shop/"
  description = "Read only the staging hml database migration credential secret."
  policy      = data.aws_iam_policy_document.migration_hml_secret_read.json
  tags        = local.tags
}

data "aws_iam_policy_document" "bootstrap_hml_secret_access" {
  statement {
    sid     = "ReadAndPublishOnlyHmlCredentialsAndSharedOwnerSecret"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue"]
    resources = [
      module.secrets.runtime_secret_arns[local.environment],
      module.secrets.lambda_secret_arns[local.environment],
      module.secrets.migration_secret_arns[local.environment],
      data.aws_ssm_parameter.owner_secret_arn.value,
    ]
  }
}

resource "aws_iam_policy" "bootstrap_hml_secret_access" {
  name        = "auto-shop-staging-db-bootstrap-hml-secrets"
  path        = "/auto-shop/"
  description = "Allow the HML database bootstrap role to publish only HML credentials and read the shared RDS owner secret."
  policy      = data.aws_iam_policy_document.bootstrap_hml_secret_access.json
  tags        = local.tags
}

data "aws_iam_policy_document" "environment_bootstrap_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:eks:${var.aws_region}:${local.account_id}:cluster/${data.aws_ssm_parameter.cluster_name.value}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["auto-shop-ops"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["auto-shop-db-bootstrap-${local.environment}"]
    }
  }
}

resource "aws_iam_role" "environment_bootstrap" {
  name                 = "auto-shop-staging-db-bootstrap-${local.environment}"
  path                 = "/auto-shop/"
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:policy/auto-shop/auto-shop-boundary"
  assume_role_policy   = data.aws_iam_policy_document.environment_bootstrap_trust.json
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "bootstrap_hml_secret_access" {
  role       = aws_iam_role.environment_bootstrap.name
  policy_arn = aws_iam_policy.bootstrap_hml_secret_access.arn
}

module "ssm_contract" {
  source = "../../../modules/ssm-contract"

  prefix = "/auto-shop/staging"
  strings = {
    "database/names/hml"                          = local.db_name
    "database/secrets/runtime-hml-arn"            = module.secrets.runtime_secret_arns[local.environment]
    "database/secrets/lambda-hml-arn"             = module.secrets.lambda_secret_arns[local.environment]
    "database/secrets/migrations-hml-arn"         = module.secrets.migration_secret_arns[local.environment]
    "database/iam/migrations-hml-read-policy-arn" = aws_iam_policy.migration_hml_secret_read.arn
    "database/iam/lambda-read-policy-arn/hml"     = aws_iam_policy.lambda_hml_secret_read.arn
    "database/iam/bootstrap-role-arn/hml"         = aws_iam_role.environment_bootstrap.arn
  }
  tags = local.tags
}
