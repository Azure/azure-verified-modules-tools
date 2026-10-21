function Assert-AvmBicepResourceIsolationTemplate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $pending = [System.Collections.Generic.Stack[object]]::new()
    $pending.Push($Template)
    $hasResources = $false
    $hasNestedDeployment = $false
    $visited = 0
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if (++$visited -gt 100) {
            throw [AvmConfigurationException]::new('Isolation cannot establish ownership through excessive nested templates.')
        }
        $resources = $current['resources']
        if ($null -eq $resources) { continue }
        $items = if ($resources -is [System.Collections.IDictionary]) { @($resources.Values) } else { @($resources) }
        foreach ($resource in $items) {
            if ($resource -isnot [System.Collections.IDictionary] -or
                $resource['type'] -isnot [string] -or
                @('scope', 'subscriptionId', 'resourceGroup' | Where-Object { $resource.Contains($_) }).Count -gt 0) {
                throw [AvmConfigurationException]::new('Isolation cannot establish a native-owned boundary for a dynamic or explicitly scoped resource.')
            }
            if ($resource['type'] -ieq 'Microsoft.Resources/deployments') {
                $hasNestedDeployment = $true
                $properties = $resource['properties']
                if ($properties -isnot [System.Collections.IDictionary] -or $properties.Contains('templateLink')) {
                    throw [AvmConfigurationException]::new('Isolation cannot establish ownership of an external nested template.')
                }
                $nested = $properties['template']
                if ($nested -is [string] -and $nested -cmatch "^\[variables\('([^']+)'\)\]$") {
                    $variables = $current['variables']
                    $nested = if ($variables -is [System.Collections.IDictionary]) { $variables[$Matches[1]] } else { $null }
                }
                if ($nested -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new('Isolation requires an inspectable inline or lexical variable template, not general ARM expression evaluation.')
                }
                $pending.Push($nested)
                continue
            }
            if ($resource['type'] -inotmatch '^Microsoft\.Storage/storageAccounts(?:/[^/]+)*$') {
                throw [AvmConfigurationException]::new('Isolation has no established provider/cleanup boundary for this resource type. Initial support is contained storage-account resources; service-managed infrastructure and scripts require migration.')
            }
            $hasResources = $true
            if ($resource.Contains('resources')) {
                throw [AvmConfigurationException]::new('Isolation requires flattened resource declarations so every cleanup target type is inspected.')
            }
        }
    }
    if ([string]$Template['$schema'] -imatch '/deploymentTemplate\.json#?$') { return 'OwnedResourceGroup' }
    if ($hasResources -or $hasNestedDeployment) {
        throw [AvmConfigurationException]::new('Isolation cannot bind these resources to a fresh native-owned group; test-created or service-managed boundaries remain unestablished.')
    }
    return 'Empty'
}
