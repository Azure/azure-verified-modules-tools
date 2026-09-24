variable "location" {
  type        = string
  description = "The Azure location where resources will be created"
  nullable    = false
}

variable "telemetry_location" {
  type        = string
  default     = null
  description = "Optional. Location for the subscription-scoped AVM telemetry deployment. Defaults to the module location; override it for another region or cloud. See https://aka.ms/avm/telemetry."
}
