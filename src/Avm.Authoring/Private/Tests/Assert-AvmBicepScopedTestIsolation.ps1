function Assert-AvmBicepScopedTestIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant')]
        [string] $Scope,

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
    $allowed = @(
        'Microsoft.Authorization/policyDefinitions'
        'Microsoft.Authorization/policySetDefinitions'
        'Microsoft.Authorization/roleDefinitions'
    )
    if ($Scope -eq 'sub') {
        $allowed += 'Microsoft.Resources/resourceGroups'
    }
    foreach ($resource in $resources) {
        if ($resource -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has an invalid ARM resource.")
        }
        foreach ($property in @('scope', 'subscriptionId', 'resourceGroup', 'managementGroupId', 'tenantId')) {
            if ($resource.Contains($property)) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' contains a cross-scope resource ($property); this scope is not yet approved.")
            }
        }
        $type = [string]$resource['type']
        if ($type -cnotmatch '^[A-Za-z0-9.]+/[A-Za-z0-9]+$') {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has a resource type that cannot be verified.")
        }
        if ($type -eq 'Microsoft.Resources/deployments') {
            $properties = $resource['properties']
            if ($properties -isnot [System.Collections.IDictionary] -or
                $properties.Contains('templateLink') -or
                $properties['template'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' has a nested deployment without an inspectable inline template.")
            }
            if ($properties['mode'] -isnot [string] -or
                $properties['mode'] -cne 'Incremental') {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' has a nested deployment without a literal Incremental mode.")
            }
            foreach ($property in $properties.Keys) {
                if ($property -cnotin @('mode', 'template', 'parameters', 'expressionEvaluationOptions')) {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e test '$SourcePath' has an unsupported nested deployment property '$property'.")
                }
            }
            if ($properties.Contains('parameters') -and
                $properties['parameters'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' requires inline nested deployment parameters.")
            }
            if ($properties.Contains('expressionEvaluationOptions')) {
                $options = $properties['expressionEvaluationOptions']
                if ($options -isnot [System.Collections.IDictionary] -or
                    $options.Count -ne 1 -or
                    $options['scope'] -isnot [string] -or
                    $options['scope'] -cne 'inner') {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e test '$SourcePath' requires inner-scope nested expression evaluation.")
                }
            }
            Assert-AvmBicepScopedTestIsolation -Template $properties['template'] `
                -Scope $Scope -SourcePath $SourcePath
        }
        elseif ($type -notin $allowed) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' contains unsupported $Scope resource type '$type'; deployment was refused.")
        }
        if ($resource.Contains('resources')) {
            if ($resource['resources'] -isnot [array]) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' contains child resources that cannot be inspected.")
            }
            if ($resource['resources'].Count -gt 0) {
                Assert-AvmBicepScopedTestIsolation -Template @{ resources = $resource['resources'] } `
                    -Scope $Scope -SourcePath $SourcePath
            }
        }
    }
}
