function Assert-AvmBicepScopedTestIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant', 'group')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SourcePath,

        [switch] $AllowTelemetryOnly,

        [string] $OwnedGroupRunId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $resources = $Template['resources']
    $resourceList = [System.Collections.Generic.List[object]]::new()
    $symbolic = $Template.Contains('languageVersion')
    if ($symbolic) {
        if ($Template['languageVersion'] -isnot [string] -or
            $Template['languageVersion'] -cne '2.0' -or
            $resources -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has an unsupported ARM symbolic resource shape.")
        }
        $symbols = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $resources.Keys) {
            if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
                -not $symbols.Add($name)) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' has an invalid or duplicate ARM symbolic resource name.")
            }
            $resourceList.Add($resources[$name])
        }
    }
    elseif ($resources -is [array]) {
        foreach ($resource in $resources) {
            $resourceList.Add($resource)
        }
    }
    else {
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' has no inspectable ARM resources.")
    }
    if ($resourceList.Count -eq 0) {
        if ($AllowTelemetryOnly) {
            Assert-AvmBicepScopedTelemetryTemplate -Template $Template -SourcePath $SourcePath
            return
        }
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' has no inspectable ARM resources.")
    }
    $allowed = if ($Scope -eq 'group') {
        @('Microsoft.Network/routeTables')
    }
    else {
        @(
            'Microsoft.Authorization/policyDefinitions'
            'Microsoft.Authorization/policySetDefinitions'
            'Microsoft.Authorization/roleDefinitions'
        )
    }
    $ownedGroup = $null
    $crossGroupCount = 0
    if ($Scope -eq 'sub' -and -not [string]::IsNullOrWhiteSpace($OwnedGroupRunId)) {
        if ($OwnedGroupRunId -cnotmatch '^[0-9a-f]{32}$') {
            throw [AvmConfigurationException]::new('Bicep e2e run ID must be 32 lowercase hexadecimal characters.')
        }
        $groups = @($resourceList | Where-Object {
                $_ -is [System.Collections.IDictionary] -and
                $_['type'] -ceq 'Microsoft.Resources/resourceGroups'
            })
        $crossGroupCount = @($resourceList | Where-Object {
                $_ -is [System.Collections.IDictionary] -and $_.Contains('resourceGroup')
            }).Count
        if ($crossGroupCount -gt 0) {
            if ($groups.Count -ne 1 -or $crossGroupCount -ne 1 -or
                $resourceList.Count -ne 2) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' requires exactly one new group and one group deployment.")
            }
            $ownedGroup = $groups[0]
            $tags = $ownedGroup['tags']
            if ($ownedGroup['name'] -isnot [string] -or
                $ownedGroup['name'] -cnotmatch '^\[parameters\(''[A-Za-z][A-Za-z0-9_]*''\)\]$' -or
                $ownedGroup.Contains('condition') -or $ownedGroup.Contains('copy') -or
                $tags -isnot [System.Collections.IDictionary] -or
                $tags['avm-e2e-run-id'] -isnot [string] -or
                $tags['avm-e2e-run-id'] -cne $OwnedGroupRunId) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' requires an unconditional run-owned group with a parameterized name.")
            }
        }
    }
    if ($Scope -eq 'sub') {
        $allowed += 'Microsoft.Resources/resourceGroups'
    }
    foreach ($resource in $resourceList) {
        if ($resource -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has an invalid ARM resource.")
        }
        $groupDeployment = $null -ne $ownedGroup -and $resource.Contains('resourceGroup')
        foreach ($property in @('scope', 'subscriptionId', 'resourceGroup', 'managementGroupId', 'tenantId')) {
            if ($resource.Contains($property) -and
                -not ($groupDeployment -and $property -eq 'resourceGroup')) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' contains a cross-scope resource ($property); this scope is not yet approved.")
            }
        }
        $type = [string]$resource['type']
        if ($type -cnotmatch '^[A-Za-z0-9.]+/[A-Za-z0-9]+$') {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has a resource type that cannot be verified.")
        }
        if ($groupDeployment) {
            $groupName = [string]$ownedGroup['name']
            $groupReference = $groupName.Substring(1, $groupName.Length - 2)
            $expectedDependency = "[subscriptionResourceId('Microsoft.Resources/resourceGroups', $groupReference)]"
            $dependsOn = $resource['dependsOn']
            if ($type -cne 'Microsoft.Resources/deployments' -or
                $resource['resourceGroup'] -isnot [string] -or
                $resource['resourceGroup'] -cne $groupName -or
                $resource.Contains('copy') -or $resource.Contains('condition') -or
                $dependsOn -isnot [array] -or $dependsOn.Count -ne 1 -or
                $dependsOn[0] -isnot [string] -or
                $dependsOn[0] -cne $expectedDependency) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' has an unverified or repeated group deployment.")
            }
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
            if (($groupDeployment -or $Scope -eq 'group') -and
                $properties.Contains('parameters')) {
                foreach ($parameter in $properties['parameters'].Values) {
                    if ($parameter -isnot [System.Collections.IDictionary] -or
                        $parameter.Count -ne 1 -or -not $parameter.Contains('value')) {
                        throw [AvmConfigurationException]::new(
                            "Bicep e2e test '$SourcePath' has an uninspectable group deployment parameter.")
                    }
                }
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
            $nestedScope = if ($groupDeployment) { 'group' } else { $Scope }
            if ($groupDeployment) {
                $nestedSchema = $properties['template']['$schema']
                if ($nestedSchema -isnot [string] -or
                    $nestedSchema -cnotmatch '^https://schema\.management\.azure\.com/schemas/\d{4}-\d{2}-\d{2}/deploymentTemplate\.json#$') {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e test '$SourcePath' has a group deployment without an inline resource-group template.")
                }
            }
            Assert-AvmBicepScopedTestIsolation -Template $properties['template'] `
                -Scope $nestedScope -SourcePath $SourcePath -AllowTelemetryOnly
        }
        elseif ($type -notin $allowed) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' contains unsupported $Scope resource type '$type'; deployment was refused.")
        }
        if ($resource.Contains('resources')) {
            $children = $resource['resources']
            if ($children -isnot [array] -and
                -not ($symbolic -and $children -is [System.Collections.IDictionary])) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$SourcePath' contains child resources that cannot be inspected.")
            }
            if ($children.Count -gt 0) {
                $childTemplate = @{ resources = $children }
                if ($children -is [System.Collections.IDictionary]) {
                    $childTemplate.languageVersion = '2.0'
                }
                Assert-AvmBicepScopedTestIsolation -Template $childTemplate `
                    -Scope $Scope -SourcePath $SourcePath
            }
        }
    }
}
