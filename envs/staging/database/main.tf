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

data "aws_secretsmanager_secret" "runtime" {
  for_each = toset(["hml", "prd"])

  name = "auto-shop/staging/${each.value}/app-runtime"
}

data "aws_secretsmanager_secret" "lambda" {
  for_each = toset(["hml", "prd"])

  name = "auto-shop/staging/${each.value}/lambda-auth"
}

locals {
  account_id   = "035611741563"
  partition    = data.aws_partition.current.partition
  cluster_name = data.aws_ssm_parameter.eks_cluster_name.value
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/auto-shop/auto-shop-boundary"
  cluster_arn  = "arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/${local.cluster_name}"
  db_names     = { for environment in ["hml", "prd"] : environment => "autoshop_${environment}" }
  # AWS marks SSM parameter values sensitive even though this StringList is network metadata.
  isolated_subnet_ids = nonsensitive([
    for subnet_id in split(",", data.aws_ssm_parameter.rds_subnet_ids.value) : trimspace(subnet_id)
  ])
  tags = {
    Project     = "auto-shop"
    Repository  = "database-infra"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }

  runtime_secret_arns = {
    for environment, secret in data.aws_secretsmanager_secret.runtime : environment => secret.arn
  }
  lambda_secret_arns = {
    for environment, secret in data.aws_secretsmanager_secret.lambda : environment => secret.arn
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

module "ssm_contract" {
  source = "../../../modules/ssm-contract"

  prefix = "/auto-shop/staging"
  strings = {
    "database/host"              = module.instance.address
    "database/port"              = tostring(module.instance.port)
    "database/security-group-id" = module.network.security_group_id
    "database/secrets/owner-arn" = module.instance.master_user_secret_arn
  }
  tags = local.tags
}
