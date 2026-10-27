variable "name" {
  description = "RDS instance identifier."
  type        = string
}

variable "db_subnet_group_name" {
  description = "Private database subnet group name."
  type        = string
}

variable "security_group_id" {
  description = "Database security group ID."
  type        = string
}

variable "backup_window" {
  description = "Daily UTC backup window."
  type        = string
}

variable "backup_retention_period" {
  description = "Backup retention in days; ephemeral staging keeps one day."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_period == 1
    error_message = "Ephemeral staging must retain automated backups for exactly one day."
  }
}

variable "multi_az" {
  description = "Multi-AZ is disabled for this cost-bounded ephemeral staging instance."
  type        = bool
  default     = false

  validation {
    condition     = var.multi_az == false
    error_message = "The ephemeral staging database must remain Single-AZ."
  }
}

variable "tags" {
  description = "Tags applied to the RDS instance and parameter group."
  type        = map(string)
  default     = {}
}
