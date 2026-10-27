mock_provider "aws" {}

variables {
  name                       = "auto-shop-staging-rds"
  vpc_id                     = "vpc-12345678"
  subnet_ids                 = ["subnet-11111111", "subnet-22222222"]
  allowed_security_group_ids = { eks-nodes = "sg-11111111", lambda = "sg-22222222" }
  tags                       = { Project = "auto-shop", Environment = "staging" }
}

run "uses_isolated_subnets_and_security_group_references_only" {
  command   = apply
  state_key = "network_rules_lifecycle"

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = {
      id                = "subnet-11111111"
      vpc_id            = "vpc-12345678"
      availability_zone = "us-east-1a"
    }
  }

  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = {
      id                = "subnet-22222222"
      vpc_id            = "vpc-12345678"
      availability_zone = "us-east-1b"
    }
  }

  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [] }
  }

  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  assert {
    condition     = toset(aws_db_subnet_group.this.subnet_ids) == toset(["subnet-11111111", "subnet-22222222"])
    error_message = "The RDS subnet group must contain only the supplied isolated subnets."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 2
    error_message = "There must be exactly one ingress rule for each approved source security group."
  }

  assert {
    condition = alltrue([
      for rule in values(aws_vpc_security_group_ingress_rule.this) :
      rule.ip_protocol == "tcp" &&
      rule.from_port == 5432 &&
      rule.to_port == 5432 &&
      rule.referenced_security_group_id != null &&
      rule.cidr_ipv4 == null &&
      rule.cidr_ipv6 == null
    ])
    error_message = "PostgreSQL ingress must use only approved security group references on TCP 5432."
  }

  assert {
    condition     = try(length(aws_security_group.this.ingress), 0) == 0 && length(aws_security_group.this.egress) == 0
    error_message = "The RDS security group must have no inline rules and no egress."
  }
}

run "second_plan_preserves_standalone_ingress_without_inline_rule_drift" {
  command   = plan
  state_key = "network_rules_lifecycle"

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = {
      id                = "subnet-11111111"
      vpc_id            = "vpc-12345678"
      availability_zone = "us-east-1a"
    }
  }

  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = {
      id                = "subnet-22222222"
      vpc_id            = "vpc-12345678"
      availability_zone = "us-east-1b"
    }
  }

  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [] }
  }

  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 2
    error_message = "A second plan must retain both standalone PostgreSQL ingress rules."
  }

  assert {
    condition     = try(length(aws_security_group.this.ingress), 0) == 0 && length(aws_security_group.this.egress) == 0
    error_message = "A second plan must not reintroduce inline ingress or egress rules."
  }
}

run "rejects_fewer_than_two_subnets" {
  command = plan

  variables {
    subnet_ids = ["subnet-11111111"]
  }

  expect_failures = [var.subnet_ids]
}

run "rejects_duplicate_subnet_ids" {
  command = plan

  variables {
    subnet_ids = ["subnet-11111111", "subnet-11111111"]
  }

  expect_failures = [var.subnet_ids]
}

run "rejects_malformed_subnet_ids" {
  command = plan

  variables {
    subnet_ids = ["not-a-subnet-id", "subnet-22222222"]
  }

  expect_failures = [var.subnet_ids]
}

run "rejects_empty_source_map" {
  command = plan

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = { id = "subnet-11111111", vpc_id = "vpc-12345678", availability_zone = "us-east-1a" }
  }
  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = { id = "subnet-22222222", vpc_id = "vpc-12345678", availability_zone = "us-east-1b" }
  }
  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [] }
  }
  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  variables {
    allowed_security_group_ids = {}
  }

  expect_failures = [var.allowed_security_group_ids]
}

run "rejects_subnets_outside_the_expected_vpc" {
  command = plan

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = { id = "subnet-11111111", vpc_id = "vpc-87654321", availability_zone = "us-east-1a" }
  }
  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = { id = "subnet-22222222", vpc_id = "vpc-12345678", availability_zone = "us-east-1b" }
  }
  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [] }
  }
  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  expect_failures = [aws_db_subnet_group.this]
}

run "rejects_subnets_in_one_availability_zone" {
  command = plan

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = { id = "subnet-11111111", vpc_id = "vpc-12345678", availability_zone = "us-east-1a" }
  }
  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = { id = "subnet-22222222", vpc_id = "vpc-12345678", availability_zone = "us-east-1a" }
  }
  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [] }
  }
  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  expect_failures = [aws_db_subnet_group.this]
}

run "rejects_default_ipv4_route" {
  command = plan

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = { id = "subnet-11111111", vpc_id = "vpc-12345678", availability_zone = "us-east-1a" }
  }
  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = { id = "subnet-22222222", vpc_id = "vpc-12345678", availability_zone = "us-east-1b" }
  }
  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-12345678" }] }
  }
  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  expect_failures = [aws_db_subnet_group.this]
}

run "rejects_default_ipv6_route" {
  command = plan

  override_data {
    target = data.aws_subnet.this["subnet-11111111"]
    values = { id = "subnet-11111111", vpc_id = "vpc-12345678", availability_zone = "us-east-1a" }
  }
  override_data {
    target = data.aws_subnet.this["subnet-22222222"]
    values = { id = "subnet-22222222", vpc_id = "vpc-12345678", availability_zone = "us-east-1b" }
  }
  override_data {
    target = data.aws_route_table.this["subnet-11111111"]
    values = { routes = [{ ipv6_cidr_block = "::/0", egress_only_gateway_id = "eigw-12345678" }] }
  }
  override_data {
    target = data.aws_route_table.this["subnet-22222222"]
    values = { routes = [] }
  }

  expect_failures = [aws_db_subnet_group.this]
}
