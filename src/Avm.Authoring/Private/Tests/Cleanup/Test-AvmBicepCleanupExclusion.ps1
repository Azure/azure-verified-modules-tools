function Test-AvmBicepCleanupExclusion {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $prefix = "/subscriptions/$SubscriptionId"
    if ($ResourceId -ieq "$prefix/resourceGroups/NetworkWatcherRG") {
        return $true
    }
    foreach ($type in @(
            'autoProvisioningSettings', 'deviceSecurityGroups', 'iotSecuritySolutions',
            'pricings', 'securityContacts', 'workspaceSettings'
        )) {
        if ($ResourceId.StartsWith(
                "$prefix/providers/Microsoft.Security/$type/",
                [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}
