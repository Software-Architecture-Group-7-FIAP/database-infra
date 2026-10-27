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
    condition     = toset(var.environments) == toset(["hml", "prd"]) && length(var.environments) == 2
    error_message = "Only the hml and prd logical databases are supported."
  }
}

variable "tags" {
  description = "Tags applied to secret metadata resources."
  type        = map(string)
  default     = {}
}
