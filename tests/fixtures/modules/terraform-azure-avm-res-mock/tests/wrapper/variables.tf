variable "location" {
  type        = string
  description = "The Azure location passed to the module under test."
  nullable    = false
}

variable "create_example_resources" {
  type        = bool
  default     = false
  description = "The legacy resource-creation input passed to the module under test."
  nullable    = false
}

variable "create_mock_resources" {
  type        = bool
  default     = false
  description = "The current resource-creation input passed to the module under test."
  nullable    = false
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Whether the module under test should create its telemetry resource."
  nullable    = false
}
