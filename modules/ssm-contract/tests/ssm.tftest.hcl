mock_provider "aws" {}

variables {
  prefix  = "/auto-shop/staging"
  strings = { "network/vpc-id" = "vpc-123" }
  lists   = { "network/workload-private-subnet-ids" = ["subnet-a", "subnet-b"] }
}

run "publishes_only_plain_parameters_under_prefix" {
  command = apply

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.string : p.type == "String"]) && alltrue([for p in aws_ssm_parameter.list : p.type == "StringList"])
    error_message = "Contracts must never use SecureString."
  }

  assert {
    condition     = jsonencode(output.parameter_names) == jsonencode(["/auto-shop/staging/network/vpc-id", "/auto-shop/staging/network/workload-private-subnet-ids"])
    error_message = "Parameter names must be prefix + relative key."
  }

  assert {
    condition     = aws_ssm_parameter.list["network/workload-private-subnet-ids"].value == "subnet-a,subnet-b"
    error_message = "StringList values must be comma separated."
  }
}

run "rejects_foreign_prefix" {
  command = plan

  variables {
    prefix = "/other/staging"
  }

  expect_failures = [var.prefix]
}
