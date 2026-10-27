provider "aws" {
  region              = var.aws_region
  allowed_account_ids = ["035611741563"]
}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/auto-shop/staging/network/vpc-id"
}

data "aws_ssm_parameter" "rds_subnet_ids" {
  name = "/auto-shop/staging/network/rds-isolated-subnet-ids"
}

data "aws_ssm_parameter" "eks_node_sg_id" {
  name = "/auto-shop/staging/network/eks-node-security-group-id"
}

data "aws_ssm_parameter" "lambda_sg_id" {
  name = "/auto-shop/staging/network/lambda-security-group-id"
}

data "aws_ssm_parameter" "eks_cluster_name" {
  name = "/auto-shop/staging/eks/cluster-name"
}

locals {
  account_id   = "035611741563"
  partition    = data.aws_partition.current.partition
  cluster_name = data.aws_ssm_parameter.eks_cluster_name.value
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/auto-shop/auto-shop-boundary"
  cluster_arn  = "arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/${local.cluster_name}"

  # The provider marks every SSM parameter value sensitive, including this non-secret StringList.
  # db-network validates the subnet IDs before using them as data-source for_each keys.
  isolated_subnet_ids = nonsensitive([
    for subnet_id in split(",", data.aws_ssm_parameter.rds_subnet_ids.value) : trimspace(subnet_id)
  ])
  db_names = { for environment in var.environments : environment => "autoshop_${environment}" }
  tags = {
    Project     = "auto-shop"
    Repository  = "database-infra"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }
}

module "network" {
  source = "../../../modules/db-network"

  name       = "auto-shop-staging-db"
  vpc_id     = data.aws_ssm_parameter.vpc_id.value
  subnet_ids = local.isolated_subnet_ids
  allowed_security_group_ids = {
    eks-nodes = data.aws_ssm_parameter.eks_node_sg_id.value
    lambda    = data.aws_ssm_parameter.lambda_sg_id.value
  }
  tags = local.tags
}

module "secrets" {
  source = "../../../modules/db-secrets"

  prefix       = "auto-shop/staging"
  environments = var.environments
  tags         = local.tags
}

module "instance" {
  source = "../../../modules/db-instance"

  name                    = "auto-shop-staging"
  db_subnet_group_name    = module.network.subnet_group_name
  security_group_id       = module.network.security_group_id
  backup_window           = "03:00-04:00"
  backup_retention_period = 1
  multi_az                = false
  tags                    = local.tags
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.cluster_arn]
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
      values   = ["auto-shop-db-bootstrap"]
    }
  }
}

resource "aws_iam_role" "db_bootstrap" {
  name                 = "auto-shop-staging-db-bootstrap"
  path                 = "/auto-shop/"
  permissions_boundary = local.boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_trust.json
  tags                 = local.tags
}

data "aws_iam_policy_document" "db_bootstrap" {
  statement {
    sid       = "ReadRdsMasterSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.instance.master_user_secret_arn]
  }

  statement {
    sid       = "ReadPublishedApplicationCredentialsForRetry"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = concat(values(module.secrets.runtime_secret_arns), values(module.secrets.lambda_secret_arns))
  }

  statement {
    sid       = "PublishApplicationCredentials"
    actions   = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = concat(values(module.secrets.runtime_secret_arns), values(module.secrets.lambda_secret_arns))
  }
}

resource "aws_iam_role_policy" "db_bootstrap" {
  name   = "auto-shop-staging-db-bootstrap-secrets"
  role   = aws_iam_role.db_bootstrap.id
  policy = data.aws_iam_policy_document.db_bootstrap.json
}

resource "aws_eks_pod_identity_association" "db_bootstrap" {
  cluster_name    = local.cluster_name
  namespace       = "auto-shop-ops"
  service_account = "auto-shop-db-bootstrap"
  role_arn        = aws_iam_role.db_bootstrap.arn
}

data "aws_iam_policy_document" "owner_secret_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.instance.master_user_secret_arn]
  }
}

resource "aws_iam_policy" "owner_secret_read" {
  name        = "auto-shop-staging-db-read-owner"
  path        = "/auto-shop/"
  description = "Read only the staging RDS-managed master secret for the approved migrations identity."
  policy      = data.aws_iam_policy_document.owner_secret_read.json
  tags        = local.tags
}

data "aws_iam_policy_document" "lambda_hml_secret_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.secrets.lambda_secret_arns["hml"]]
  }
}

resource "aws_iam_policy" "lambda_hml_secret_read" {
  name        = "auto-shop-staging-db-read-lambda-hml"
  path        = "/auto-shop/"
  description = "Read only the staging hml Lambda credential secret."
  policy      = data.aws_iam_policy_document.lambda_hml_secret_read.json
  tags        = local.tags
}

data "aws_iam_policy_document" "lambda_prd_secret_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.secrets.lambda_secret_arns["prd"]]
  }
}

resource "aws_iam_policy" "lambda_prd_secret_read" {
  name        = "auto-shop-staging-db-read-lambda-prd"
  path        = "/auto-shop/"
  description = "Read only the staging prd Lambda credential secret."
  policy      = data.aws_iam_policy_document.lambda_prd_secret_read.json
  tags        = local.tags
}

module "ssm_contract" {
  source = "../../../modules/ssm-contract"

  prefix = "/auto-shop/staging"
  strings = {
    "database/host"                           = module.instance.address
    "database/port"                           = tostring(module.instance.port)
    "database/security-group-id"              = module.network.security_group_id
    "database/names/hml"                      = local.db_names["hml"]
    "database/names/prd"                      = local.db_names["prd"]
    "database/secrets/runtime-hml-arn"        = module.secrets.runtime_secret_arns["hml"]
    "database/secrets/runtime-prd-arn"        = module.secrets.runtime_secret_arns["prd"]
    "database/secrets/lambda-hml-arn"         = module.secrets.lambda_secret_arns["hml"]
    "database/secrets/lambda-prd-arn"         = module.secrets.lambda_secret_arns["prd"]
    "database/secrets/owner-arn"              = module.instance.master_user_secret_arn
    "database/iam/owner-read-policy-arn"      = aws_iam_policy.owner_secret_read.arn
    "database/iam/lambda-read-policy-arn/hml" = aws_iam_policy.lambda_hml_secret_read.arn
    "database/iam/lambda-read-policy-arn/prd" = aws_iam_policy.lambda_prd_secret_read.arn
  }
  tags = local.tags
}
