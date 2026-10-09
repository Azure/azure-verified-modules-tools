function Get-AvmBicepCleanupResourceRecord {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [object[]])]
    param(
        [object[]] $Existing = @(),
        [string[]] $ResourceIds = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $records = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $Existing) { $records.Add($record['id'], $record) }
    foreach ($resource in ConvertTo-AvmBicepCleanupResource -ResourceIds $ResourceIds) {
        if ($resource.type -ieq 'Microsoft.Resources/deployments') {
            throw [AvmConfigurationException]::new('Deployment history must not be recorded as a cleanup resource.')
        }
        if (-not $records.ContainsKey($resource.resourceId)) {
            $records.Add($resource.resourceId, [ordered]@{
                    id = $resource.resourceId; type = $resource.type
                    removed = $false; postProcessed = $false; metadataCaptured = $false
                    managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
                })
        }
    }
    return @($records.Values)
}
