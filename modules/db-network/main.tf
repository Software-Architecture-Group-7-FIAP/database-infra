data "aws_subnet" "this" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

data "aws_route_table" "this" {
  for_each = toset(var.subnet_ids)

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Isolated subnets for the ephemeral Auto Shop staging database."
  subnet_ids  = var.subnet_ids
  tags        = var.tags

  lifecycle {
    precondition {
      condition     = alltrue([for subnet in data.aws_subnet.this : subnet.vpc_id == var.vpc_id])
      error_message = "Every database subnet must belong to the expected VPC."
    }

    precondition {
      condition     = length(distinct([for subnet in data.aws_subnet.this : subnet.availability_zone])) >= 2
      error_message = "Database subnets must span at least two Availability Zones."
    }

    precondition {
      condition = alltrue(flatten([
        for route_table in data.aws_route_table.this : [
          for route in route_table.routes :
          try(route.cidr_block != "0.0.0.0/0", true) && try(route.ipv6_cidr_block != "::/0", true)
        ]
      ]))
      error_message = "Database subnets must not have IPv4 or IPv6 default routes."
    }
  }
}

resource "aws_security_group" "this" {
  #checkov:skip=CKV2_AWS_5:This security group reaches the RDS instance through the root module output and a separate module input.
  name                   = var.name
  description            = "PostgreSQL access from explicitly approved workload security groups."
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true
  egress                 = []
  tags                   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = var.allowed_security_group_ids

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from ${each.key}."
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = var.tags
}
