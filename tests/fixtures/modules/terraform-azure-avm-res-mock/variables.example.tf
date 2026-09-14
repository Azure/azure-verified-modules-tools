variable "create_example_resources" {
  type        = bool
  default     = false
  description = "Deprecated alias for create_mock_resources. Either input enables the mock module's example resources."
  nullable    = false

  deprecated = "Use the create_mock_resources input instead."
}

variable "create_mock_resources" {
  type        = bool
  default     = false
  description = "Whether to create example Azure resources. Disabled by default; enable only in unit tests with mock providers."
  nullable    = false
}
