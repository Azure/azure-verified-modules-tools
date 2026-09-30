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

        [string] $ManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $changes = @(Read-AvmBicepWhatIfChange -Output $Output -File $File)
    if ($changes.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e what-if for '$File' predicted no resources; deployment was refused.")
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
            -RunId $RunId
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
        $tags = $after['tags']
        $ownedGroup = $tags -is [System.Collections.IDictionary]
        if ($ownedGroup) {
            $ownedGroup = $tags['avm-e2e-run-id'] -ceq $RunId
        }
        if ($resource.Kind -eq 'Group' -and -not $ownedGroup) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e group '$($resource.Id)' must include its exact avm-e2e-run-id ownership tag.")
        }
        if ($resource.Kind -eq 'Deployment') {
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
    return [pscustomobject]@{
        Resources   = $resources.ToArray()
        Deployments = $deployments.ToArray()
        Changes     = $changes
    }
}
