function Read-AvmBicepScopedWhatIf {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output,

        [Parameter(Mandatory)]
        [string] $File,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $RunId,

        [string] $ManagementGroupId,

        [switch] $RequireOwnedGroup
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $changes = @(Read-AvmBicepWhatIfChange -Output $Output -File $File)
    if ($changes.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e what-if for '$File' predicted no resources; deployment was refused.")
    }
    $ownedGroupName = ''
    if ($RequireOwnedGroup) {
        if ($Scope -ne 'sub') {
            throw [AvmConfigurationException]::new(
                'A run-owned group is supported only beneath a subscription deployment.')
        }
        $groupPattern = '^/subscriptions/{0}/resourceGroups/(?<name>[^/?#]+)$' -f [regex]::Escape($SubscriptionId)
        $groupChanges = @($changes | Where-Object { $_.ResourceId -imatch $groupPattern })
        if ($groupChanges.Count -ne 1) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' must create exactly one group in the selected subscription.")
        }
        $groupResource = Get-AvmBicepScopedResource -ResourceId $groupChanges[0].ResourceId `
            -Scope sub -SubscriptionId $SubscriptionId -RunId $RunId
        $ownedGroupName = $groupResource.Name
    }
    $plan = $Output | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $resources = [System.Collections.Generic.List[object]]::new()
    $deployments = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $changes.Count; $index++) {
        $change = $changes[$index]
        if ($change.ChangeType -cne 'Create' -or -not $seen.Add($change.ResourceId)) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' contains a non-Create or duplicate change at '$($change.ResourceId)'; deployment was refused.")
        }
        $resource = Get-AvmBicepScopedResource -ResourceId $change.ResourceId `
            -Scope $Scope -SubscriptionId $SubscriptionId -ManagementGroupId $ManagementGroupId `
            -RunId $RunId -OwnedGroupName $ownedGroupName
        $after = $plan['changes'][$index]['after']
        if ($after -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' did not expand '$($change.ResourceId)' into a full resource payload.")
        }
        if (-not [string]::Equals([string]$after['name'], $resource.Name,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$after['type'], $resource.Type,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            ($after.Contains('id') -and
            -not [string]::Equals([string]$after['id'], $resource.Id,
                [System.StringComparison]::OrdinalIgnoreCase))) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' returned an inconsistent expanded resource at '$($resource.Id)'.")
        }
        if ($RequireOwnedGroup) {
            foreach ($field in @('scope', 'subscriptionId', 'managementGroupId', 'tenantId')) {
                if ($after.Contains($field)) {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e what-if for '$File' returned an unexpected $field on '$($resource.Id)'.")
                }
            }
            if ($after.Contains('resourceGroup') -and
                ($resource.Kind -eq 'Group' -or
                $after['resourceGroup'] -isnot [string] -or
                -not [string]::Equals($after['resourceGroup'], $ownedGroupName,
                    [System.StringComparison]::OrdinalIgnoreCase))) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e what-if for '$File' returned a foreign group target for '$($resource.Id)'.")
            }
        }
        $tags = $after['tags']
        if ($RequireOwnedGroup -and $tags -is [System.Collections.IDictionary]) {
            $ownerKeys = @($tags.Keys | Where-Object { $_ -is [string] -and $_ -ieq 'avm-e2e-run-id' })
            if ($ownerKeys.Count -gt 1 -or
                ($ownerKeys.Count -eq 1 -and $ownerKeys[0] -cne 'avm-e2e-run-id')) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e what-if for '$File' returned ambiguous ownership tags for '$($resource.Id)'.")
            }
        }
        $ownedGroup = $tags -is [System.Collections.IDictionary]
        if ($ownedGroup) {
            $ownedGroup = $tags['avm-e2e-run-id'] -ceq $RunId
        }
        if ($resource.Kind -eq 'Group' -and -not $ownedGroup) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e group '$($resource.Id)' must include its exact avm-e2e-run-id ownership tag.")
        }
        if ($RequireOwnedGroup -and $resource.Kind -ne 'Group' -and
            (($null -ne $tags -and $tags -isnot [System.Collections.IDictionary]) -or
            ($tags -is [System.Collections.IDictionary] -and
            $tags.Contains('avm-e2e-run-id') -and -not $ownedGroup))) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' returned unverified ownership tags for '$($resource.Id)'.")
        }
        if ($resource.Kind -eq 'Deployment') {
            if ($RequireOwnedGroup) {
                $properties = $after['properties']
                if ($properties -isnot [System.Collections.IDictionary] -or
                    $properties['mode'] -isnot [string] -or
                    $properties['mode'] -cne 'Incremental' -or
                    $properties['template'] -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e what-if for '$File' did not expand inline group deployment '$($resource.Id)'.")
                }
                $nestedSchema = $properties['template']['$schema']
                if ($nestedSchema -isnot [string] -or
                    $nestedSchema -cnotmatch '^https://schema\.management\.azure\.com/schemas/\d{4}-\d{2}-\d{2}/deploymentTemplate\.json#$') {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e what-if for '$File' returned a non-group nested template at '$($resource.Id)'.")
                }
                $previewTemplate = @{
                    resources = @(@{
                            type       = 'Microsoft.Resources/deployments'
                            properties = $properties
                        })
                }
                Assert-AvmBicepScopedTestIsolation -Template $previewTemplate `
                    -Scope group -SourcePath $File
            }
            $deployments.Add($resource)
        }
        else {
            $resources.Add($resource)
        }
    }
    if ($resources.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e what-if for '$File' predicted no inspectable resources; deployment was refused.")
    }
    if ($RequireOwnedGroup -and
        (@($resources | Where-Object { $_.Kind -eq 'Group' }).Count -ne 1 -or
        @($resources | Where-Object { $_.Kind -eq 'Resource' }).Count -eq 0 -or
        $deployments.Count -eq 0)) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e what-if for '$File' lacks an owned group, its inline deployment or an approved group resource.")
    }
    return [pscustomobject]@{
        Resources      = $resources.ToArray()
        Deployments    = $deployments.ToArray()
        Changes        = $changes
        OwnedGroupName = $ownedGroupName
    }
}
