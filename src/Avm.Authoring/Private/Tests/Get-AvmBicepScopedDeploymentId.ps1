function Get-AvmBicepScopedDeploymentId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('group', 'sub', 'mg', 'tenant')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [string] $ResourceGroupName,

        [string] $ManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $prefix = switch ($Scope) {
        'group' {
            if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
                throw [AvmConfigurationException]::new('Resource-group deployment requires -ResourceGroupName.')
            }
            "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
        }
        'sub' { "/subscriptions/$SubscriptionId" }
        'mg' {
            if ([string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                throw [AvmConfigurationException]::new('Management-group deployment requires -ManagementGroupId.')
            }
            "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
        }
        'tenant' { '' }
    }
    return "$prefix/providers/Microsoft.Resources/deployments/$DeploymentName"
}
