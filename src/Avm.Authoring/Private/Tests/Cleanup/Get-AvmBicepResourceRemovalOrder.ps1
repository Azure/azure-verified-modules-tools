function Get-AvmBicepResourceRemovalOrder {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]] $ResourcesToOrder,

        [string[]] $RemoveFirstSequence = @(
            'Microsoft.Authorization/locks'
            'Microsoft.VirtualMachineImages/imageTemplates'
            'Microsoft.DevOpsInfrastructure/pools'
            'Microsoft.Authorization/roleAssignments'
            'Microsoft.Insights/diagnosticSettings'
            'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
            'Microsoft.Network/privateEndpoints'
            'Microsoft.Network/virtualHubs/routingIntent'
            'Microsoft.Network/azureFirewalls'
            'Microsoft.Network/expressRouteGateways'
            'Microsoft.Network/vpnGateways'
            'Microsoft.Network/p2sVpnGateways'
            'Microsoft.Network/virtualHubs'
            'Microsoft.Network/virtualWans'
            'Microsoft.OperationsManagement/solutions'
            'Microsoft.OperationalInsights/workspaces/linkedServices'
            'Microsoft.OperationalInsights/workspaces'
            'Microsoft.KeyVault/vaults'
            'Microsoft.Authorization/policyExemptions'
            'Microsoft.Authorization/policyAssignments'
            'Microsoft.Authorization/policySetDefinitions'
            'Microsoft.Authorization/policyDefinitions'
            'Microsoft.Sql/managedInstances'
            'Microsoft.MachineLearningServices/workspaces'
            'Microsoft.Compute/virtualMachines'
            'Microsoft.ContainerInstance/containerGroups'
            'Microsoft.ManagedIdentity/userAssignedIdentities'
            'Microsoft.Databricks/workspaces'
            'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
            'Microsoft.NetApp/netAppAccounts/backupPolicies'
            'Microsoft.NetApp/netAppAccounts/backupVaults/backups'
            'Microsoft.NetApp/netAppAccounts/backupVaults'
            'Microsoft.NetApp/netAppAccounts/snapshotPolicies'
            'Microsoft.NetApp/netAppAccounts/capacityPools'
            'Microsoft.Network/virtualNetworkGateways'
            'Microsoft.Network/loadBalancers'
            'Microsoft.DataProtection/backupVaults'
            'Microsoft.CognitiveServices/accounts/projects'
            'Microsoft.CognitiveServices/accounts'
            'Microsoft.KeyVault/managedHSMs/keys'
            'Microsoft.Sql/servers/databases'
            'Microsoft.Sql/servers'
            'Microsoft.Cdn/profiles'
            'Microsoft.Resources/resourceGroups'
        ),

        [string[]] $RemoveLastSequence = @('Microsoft.Subscription/aliases')
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $resourcesToOrder = @($ResourcesToOrder |
            Sort-Object -Property { $_.resourceId.Split('/').Count } -Descending -Stable)

    for ($orderIndex = ($RemoveFirstSequence.Count - 1); $orderIndex -ge 0; $orderIndex--) {
        $searchItem = $RemoveFirstSequence[$orderIndex]
        if ($elementsContained = $resourcesToOrder | Where-Object { $_.type -eq $searchItem }) {
            $resourcesToOrder = @() + $elementsContained + ($resourcesToOrder | Where-Object { $_.type -ne $searchItem })
        }
    }

    for ($orderIndex = 0; $orderIndex -lt $RemoveLastSequence.Count; $orderIndex++) {
        $searchItem = $RemoveLastSequence[$orderIndex]
        if ($elementsContained = $resourcesToOrder | Where-Object { $_.type -eq $searchItem }) {
            $resourcesToOrder = @() + ($resourcesToOrder | Where-Object { $_.type -ne $searchItem }) + $elementsContained
        }
    }

    return $resourcesToOrder
}
