mock_provider "aws" {}

run "declassifies_validated_ssm_subnet_ids_before_for_each" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_data {
    target = data.aws_ssm_parameter.vpc_id
    values = { name = "/auto-shop/staging/network/vpc-id", type = "String", value = "vpc-12345678" }
  }

  override_data {
    target = data.aws_ssm_parameter.rds_subnet_ids
    values = {
      name  = "/auto-shop/staging/network/rds-isolated-subnet-ids"
      type  = "StringList"
      value = "subnet-11111111,subnet-22222222"
    }
  }

  override_data {
    target = data.aws_ssm_parameter.eks_node_sg_id
    values = { name = "/auto-shop/staging/network/eks-node-security-group-id", type = "String", value = "sg-11111111" }
  }

  override_data {
    target = data.aws_ssm_parameter.lambda_sg_id
    values = { name = "/auto-shop/staging/network/lambda-security-group-id", type = "String", value = "sg-22222222" }
  }

  override_data {
    target = data.aws_ssm_parameter.eks_cluster_name
    values = { name = "/auto-shop/staging/eks/cluster-name", type = "String", value = "auto-shop-staging" }
  }

  override_data {
    target = data.aws_iam_policy_document.pod_identity_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.db_bootstrap
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.network.data.aws_subnet.this["subnet-11111111"]
    values = {
      id                = "subnet-11111111"
      vpc_id            = "vpc-12345678"
      availability_zone = "us-east-1a"
    }
  }

  override_data {
    target = module.network.data.aws_subnet.this["subnet-22222222"]
    values = {
      id                = "subnet-22222222"
      vpc_id            = "vpc-12345678"
      availability_zone = "us-east-1b"
    }
  }

  override_data {
    target = module.network.data.aws_route_table.this["subnet-11111111"]
    values = { routes = [] }
  }

  override_data {
    target = module.network.data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  assert {
    condition     = issensitive(data.aws_ssm_parameter.rds_subnet_ids.value)
    error_message = "The regression requires the AWS provider's sensitive StringList value semantics."
  }

  assert {
    condition     = !issensitive(local.isolated_subnet_ids) && toset(local.isolated_subnet_ids) == toset(["subnet-11111111", "subnet-22222222"])
    error_message = "Validated non-secret subnet IDs must be explicitly declassified before they become for_each keys."
  }

  assert {
    condition     = length(local.db_names) == 2 && toset(keys(local.db_names)) == toset(["hml", "prd"])
    error_message = "The shared staging database root must keep the HML and PRD logical databases in its contract."
  }
}
