function Assert-AvmBicepCleanupGroupOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [string] $ResourceId,

        [switch] $RequireExisting
    )

    Set-StrictMode -Version 3.0
    $ownerTag = (Get-AvmBicepConfiguration)['e2e']['ownershipTag']
    $ErrorActionPreference = 'Stop'
    Assert-AvmBicepIsolationBoundary -State $State -ResourceIds @($ResourceId)

    foreach ($owned in $State['ownedResourceGroups']) {
        if ($ResourceId -ine $owned['id'] -and
            -not $ResourceId.StartsWith($owned['id'] + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $group = Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup `
            -Parameters @{ Name = $owned['id'].Split('/')[-1] }
        if ($null -eq $group -and $RequireExisting) {
            throw [AvmConfigurationException]::new('The verified attempt-owned group is missing before submission.')
        }
        if ($null -ne $group -and
            ((Get-AvmPropertyValue -InputObject $group -Name 'ResourceId') -ine $owned['id'] -or
            (Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $group -Name 'Tags') -Name $ownerTag) -cne $owned['runId'])) {
            throw [AvmConfigurationException]::new('Resource-group ownership changed before cleanup.')
        }
    }
}
