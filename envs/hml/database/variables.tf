variable "aws_region" {
  description = "AWS region fixed by the shared staging database contract."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The staging database contract is fixed to us-east-1."
  }
}
