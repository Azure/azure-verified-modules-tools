function Assert-AvmBicepScopedTelemetryTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $message = "Bicep e2e test '$SourcePath' contains an unsupported telemetry-only nested template."
    $keys = @('$schema', 'contentVersion', 'resources', 'outputs')
    if ($Template.Count -ne $keys.Count -or
        @($Template.Keys | Where-Object { $_ -cnotin $keys }).Count -gt 0 -or
        $Template['$schema'] -isnot [string] -or
        $Template['$schema'] -cne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#' -or
        $Template['contentVersion'] -isnot [string] -or
        $Template['contentVersion'] -cne '1.0.0.0' -or
        $Template['resources'] -isnot [array] -or
        $Template['resources'].Count -ne 0) {
        throw [AvmConfigurationException]::new($message)
    }
    $outputs = $Template['outputs']
    if ($outputs -isnot [System.Collections.IDictionary] -or
        $outputs.Count -ne 1 -or $outputs.Keys -cnotcontains 'telemetry') {
        throw [AvmConfigurationException]::new($message)
    }
    $telemetry = $outputs['telemetry']
    if ($telemetry -isnot [System.Collections.IDictionary] -or
        $telemetry.Count -ne 2 -or
        @($telemetry.Keys | Where-Object { $_ -cnotin @('type', 'value') }).Count -gt 0 -or
        $telemetry['type'] -isnot [string] -or
        $telemetry['type'] -cne 'String' -or
        $telemetry['value'] -isnot [string] -or
        $telemetry['value'] -cne 'For more information, see https://aka.ms/avm/TelemetryInfo') {
        throw [AvmConfigurationException]::new($message)
    }
}
