variable "aws_region" {
  description = "AWS region fixed by the staging database contract."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The staging database contract is fixed to us-east-1."
  }
}

variable "environments" {
  description = "Logical databases and credential pairs hosted by the one staging RDS instance."
  type        = list(string)
  default     = ["hml", "prd"]

  validation {
    condition     = toset(var.environments) == toset(["hml", "prd"]) && length(var.environments) == 2
    error_message = "The ephemeral staging instance must contain exactly the hml and prd logical databases."
  }
}
