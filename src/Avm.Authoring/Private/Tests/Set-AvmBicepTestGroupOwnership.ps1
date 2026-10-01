function Set-AvmBicepTestGroupOwnership {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($RunId -cnotmatch '^[0-9a-f]{32}$') {
        throw [AvmConfigurationException]::new('Bicep e2e run ID must be 32 lowercase hexadecimal characters.')
    }
    $resources = $Template['resources']
    if ($Template.Contains('languageVersion')) {
        if ($Template['languageVersion'] -isnot [string] -or
            $Template['languageVersion'] -cne '2.0' -or
            $resources -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has an unsupported ARM symbolic resource shape.")
        }
        $resourceList = @($resources.Values)
    }
    elseif ($resources -is [array]) {
        $resourceList = $resources
    }
    else {
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' has no inspectable ARM resources.")
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    $hasGroupDeployment = $false
    foreach ($resource in $resourceList) {
        if ($resource -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has an invalid ARM resource.")
        }
        if ($resource['type'] -ceq 'Microsoft.Resources/resourceGroups') {
            $groups.Add($resource)
        }
        if ($resource.Contains('resourceGroup')) {
            $hasGroupDeployment = $true
        }
    }
    if ($groups.Count -gt 1) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' creates multiple resource groups; only one run-owned group is supported.")
    }
    if ($groups.Count -eq 0) {
        return [pscustomobject]@{
            Tagged             = $false
            HasGroupDeployment = $hasGroupDeployment
        }
    }

    $group = $groups[0]
    $foreignScope = @('scope', 'subscriptionId', 'managementGroupId', 'tenantId', 'resourceGroup') |
        Where-Object { $group.Contains($_) }
    if ($group['name'] -isnot [string] -or
        [string]::IsNullOrWhiteSpace($group['name']) -or
        $group.Contains('condition') -or $group.Contains('copy') -or
        @($foreignScope).Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' cannot prove unconditional creation of a group in the selected subscription.")
    }
    if ($group.Contains('tags')) {
        if ($group['tags'] -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has dynamic group tags; ownership cannot be staged safely.")
        }
        $tags = $group['tags']
    }
    else {
        $tags = [ordered]@{}
    }
    $keys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $tags.Keys) {
        if ($key -isnot [string] -or -not $keys.Add($key) -or
            $tags[$key] -isnot [string] -or
            ($key -ieq 'avm-e2e-run-id' -and $key -cne 'avm-e2e-run-id')) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' has ambiguous or nonliteral group tags.")
        }
    }
    if ($tags.Contains('avm-e2e-run-id')) {
        if ($tags['avm-e2e-run-id'] -cne $RunId) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e test '$SourcePath' already declares a different group ownership tag.")
        }
    }
    if (-not $PSCmdlet.ShouldProcess($SourcePath, 'Tag compiled Bicep test group for this run')) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e group ownership staging was declined for '$SourcePath'.")
    }
    if (-not $group.Contains('tags')) {
        $group['tags'] = $tags
    }
    if (-not $tags.Contains('avm-e2e-run-id')) {
        $tags['avm-e2e-run-id'] = $RunId
    }
    return [pscustomobject]@{
        Tagged             = $true
        HasGroupDeployment = $hasGroupDeployment
    }
}
