variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
}

variable "telemetry_location" {
  type        = string
  default     = "westus2"
  description = "Optional. Location for subscription-scoped AVM telemetry. Defaults to westus2; override it for another region or cloud."
  nullable    = false
}
