variable "prefix" {
  description = "Parameter path prefix, e.g. /auto-shop/staging."
  type        = string

  validation {
    condition     = can(regex("^/auto-shop/[a-z0-9-]+$", var.prefix))
    error_message = "prefix must look like /auto-shop/<environment>."
  }
}

variable "strings" {
  description = "Non-secret String parameters, keyed by path relative to prefix."
  type        = map(string)
  default     = {}
}

variable "lists" {
  description = "Non-secret StringList parameters, keyed by path relative to prefix."
  type        = map(list(string))
  default     = {}
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
