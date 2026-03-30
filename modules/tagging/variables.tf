variable "team" {
  description = "Team that owns this resource. Used for cost attribution and alerting."
  type        = string
  validation {
    condition     = length(var.team) >= 2 && length(var.team) <= 64
    error_message = "team must be between 2 and 64 characters."
  }
}

variable "service" {
  description = "Name of the service or component. Used for service-level cost breakdown."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.service))
    error_message = "service must be lowercase alphanumeric with hyphens, e.g. 'event-ingestion'."
  }
}

variable "environment" {
  description = "Deployment environment for cost isolation."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod", "sandbox"], var.environment)
    error_message = "environment must be one of: dev, staging, prod, sandbox."
  }
}

variable "cost_center" {
  description = "Finance cost center code for chargeback/showback. Format: CC-NNNN."
  type        = string
  validation {
    condition     = can(regex("^CC-[0-9]{4}$", var.cost_center))
    error_message = "cost_center must be in format CC-NNNN, e.g. 'CC-1001'."
  }
}

variable "owner" {
  description = "Email address of the team or individual responsible for this resource."
  type        = string
  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.owner))
    error_message = "owner must be a valid email address."
  }
}

variable "additional_tags" {
  description = "Optional additional tags to merge with the standard tag set."
  type        = map(string)
  default     = {}
}
