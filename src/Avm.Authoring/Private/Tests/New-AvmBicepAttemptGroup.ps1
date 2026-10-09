function New-AvmBicepAttemptGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Location
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $State['subscriptionId'], $Name
    if (-not $PSCmdlet.ShouldProcess($groupId, 'Create an attempt-owned resource group')) { return }
    if ($null -ne (Invoke-AvmBicepCleanupLookup -Command 'Get-AzResourceGroup' -Parameters @{ Name = $Name })) {
        throw [AvmConfigurationException]::new("Refusing to use existing resource group '$Name'.")
    }
    $State['ownedResourceGroups'] = @($State['ownedResourceGroups']) + @{ id = $groupId; runId = $State['runId'] }
    Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
    $ownerTag = (Get-AvmBicepConfiguration)['e2e']['ownershipTag']
    $group = New-AzResourceGroup -Name $Name -Location $Location -Tag @{ $ownerTag = $State['runId'] } -ErrorAction Stop
    $actualId = Get-AvmPropertyValue -InputObject $group -Name 'ResourceId' -NoEnumerate
    $tags = Get-AvmPropertyValue -InputObject $group -Name 'Tags' -NoEnumerate
    $actualOwner = Get-AvmPropertyValue -InputObject $tags -Name $ownerTag -NoEnumerate
    if ($group -is [System.Collections.IList] -or $actualId -isnot [string] -or $actualId -ine $groupId -or
        $actualOwner -isnot [string] -or $actualOwner -cne $State['runId']) {
        throw [AvmProcessException]::new('The new resource group identity and ownership tag could not be verified.')
    }
}
