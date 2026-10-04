function Initialize-AvmBicepCleanupResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Resource['metadataCaptured']) {
        return
    }
    switch ($Resource['type']) {
        'Microsoft.Databricks/workspaces' {
            $workspace = Invoke-AvmBicepCleanupLookup -Command 'Get-AzResource' -Parameters @{
                ResourceId       = $Resource['id']
                ExpandProperties = $true
            }
            if ($null -ne $workspace) {
                $properties = Get-AvmPropertyValue -InputObject $workspace -Name 'Properties'
                $managedId = Get-AvmPropertyValue -InputObject $properties -Name 'managedResourceGroupId'
                if ($managedId -isnot [string] -or [string]::IsNullOrWhiteSpace($managedId)) {
                    throw [AvmProcessException]::new('Databricks did not report its managed resource-group ID.')
                }
                $managed = ConvertTo-AvmBicepCleanupResource -ResourceIds @($managedId)
                if ($managed.type -ine 'Microsoft.Resources/resourceGroups' -or
                    $managedId.Split('/')[2] -ine $Resource['id'].Split('/')[2]) {
                    throw [AvmProcessException]::new('Databricks reported an unexpected managed resource-group ID.')
                }
                $Resource['managedResourceGroupIds'] = @($managedId)
            }
            else {
                $Resource['managedResourceGroupIds'] = @(
                    Get-AzResourceGroup -ErrorAction Stop |
                        Where-Object {
                            (Get-AvmPropertyValue -InputObject $_ -Name 'ManagedBy') -ieq $Resource['id']
                        } |
                        ForEach-Object { $_.ResourceId }
                )
            }
        }
        'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems' {
            $vaultId = $Resource['id'].Substring(
                0, $Resource['id'].IndexOf('/backupFabrics/', [System.StringComparison]::OrdinalIgnoreCase))
            $vault = Invoke-AvmBicepCleanupLookup -Command 'Get-AzRecoveryServicesVaultProperty' -Parameters @{
                VaultId = $vaultId
            }
            if ($null -ne $vault) {
                $setting = Get-AvmPropertyValue -InputObject $vault -Name 'SoftDeleteFeatureState'
                if ($setting -isnot [string] -or $setting -cnotin @('Enabled', 'Disabled', 'AlwaysON')) {
                    throw [AvmProcessException]::new('Recovery Services did not report a recognized soft-delete setting.')
                }
                $Resource['originalSoftDeleteFeatureState'] = $setting
            }
        }
    }
    $Resource['metadataCaptured'] = $true
}
