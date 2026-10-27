variable "name" {
  description = "Name used for the RDS subnet group and security group."
  type        = string
}

variable "vpc_id" {
  description = "Expected VPC containing the isolated database subnets."
  type        = string
}

variable "subnet_ids" {
  description = "At least two unique isolated subnet IDs in distinct Availability Zones."
  type        = list(string)

  validation {
    condition = (
      length(var.subnet_ids) >= 2 &&
      length(distinct(var.subnet_ids)) == length(var.subnet_ids) &&
      alltrue([for id in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", id))])
    )
    error_message = "subnet_ids must contain at least two unique, valid subnet IDs."
  }
}

variable "allowed_security_group_ids" {
  description = "Approved workload security groups, keyed by workload name."
  type        = map(string)

  validation {
    condition     = length(var.allowed_security_group_ids) > 0 && alltrue([for id in values(var.allowed_security_group_ids) : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "At least one valid security group ID must be supplied; CIDR sources are not accepted."
  }
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}
