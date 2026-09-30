function Assert-AvmBicepTestIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $resources = $Template['resources']
    if ($resources -isnot [array] -or $resources.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' has no inspectable ARM resources.")
    }
    foreach ($resource in $resources) {
        if ($resource -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has an invalid ARM resource.")
        }
        foreach ($property in @('scope', 'subscriptionId', 'resourceGroup', 'managementGroupId', 'tenantId')) {
            if ($resource.Contains($property)) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' contains a cross-scope ARM resource ($property); only isolated resource-group deployments are supported.")
            }
        }
        $type = [string]$resource['type']
        if ([string]::IsNullOrWhiteSpace($type) -or $type -match '[\[\]]') {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has a resource type that cannot be verified.")
        }
        if ($type -in @('Microsoft.Resources/deploymentScripts', 'Microsoft.Resources/resourceGroups') -or
            $type -like 'Microsoft.Authorization/*') {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' contains '$type', which cannot be safely contained in a disposable group.")
        }
        if ($type -eq 'Microsoft.Resources/deployments') {
            $properties = $resource['properties']
            if ($properties -isnot [System.Collections.IDictionary] -or
                $properties.Contains('templateLink') -or
                $properties['template'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' has a nested deployment without an inspectable inline template.")
            }
            Assert-AvmBicepTestIsolation -Template $properties['template'] -SourcePath $SourcePath
        }
        if ($resource.Contains('resources')) {
            if ($resource['resources'] -isnot [array]) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' contains child resources that cannot be inspected.")
            }
            if ($resource['resources'].Count -gt 0) {
                Assert-AvmBicepTestIsolation -Template @{ resources = $resource['resources'] } `
                    -SourcePath $SourcePath
            }
        }
    }
}
