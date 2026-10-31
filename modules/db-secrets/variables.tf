variable "prefix" {
  description = "Secret path prefix, for example auto-shop/staging."
  type        = string

  validation {
    condition     = can(regex("^auto-shop/[a-z0-9-]+$", var.prefix))
    error_message = "prefix must be auto-shop/<environment>."
  }
}

variable "environments" {
  description = "Logical databases that receive runtime and Lambda authentication secret metadata."
  type        = list(string)
  default     = ["hml", "prd"]

  validation {
    condition = (
      length(var.environments) > 0 &&
      length(var.environments) == length(toset(var.environments)) &&
      alltrue([for environment in var.environments : contains(["hml", "prd"], environment)])
    )
    error_message = "environments must contain a unique, non-empty subset of hml and prd."
  }
}

variable "tags" {
  description = "Tags applied to secret metadata resources."
  type        = map(string)
  default     = {}
}
