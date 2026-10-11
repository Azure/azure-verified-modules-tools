function Remove-AvmBicepResourceRemainder {

    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceId,

        [Parameter(Mandatory = $true)]
        [string] $Type,

        [ValidateRange(1, 10)]
        [int] $PostRemovalRetryLimit = 3,

        [string[]] $ManagedResourceGroupIds = @(),

        [ValidateSet('', 'Enabled', 'Disabled', 'AlwaysON')]
        [string] $OriginalSoftDeleteFeatureState = '',

        # Relocation mode: purge protection or a remaining soft-deleted record blocks completion.
        [switch] $RequireCompleteRemoval
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $PSCmdlet.ShouldProcess($ResourceId, 'Complete Bicep test resource cleanup')) {
        return
    }
    $restoreSoftDeleteStatus = $OriginalSoftDeleteFeatureState
    $removalRetryCount = 1
    do {
        try {
            switch ($Type) {
                'Microsoft.AppConfiguration/configurationStores' {
                    $subscriptionId = $ResourceId.Split('/')[2]
                    $resourceName = $ResourceId.Split('/')[-1]

                    $getPath = '/subscriptions/{0}/providers/Microsoft.AppConfiguration/deletedConfigurationStores?api-version=2021-10-01-preview' -f $subscriptionId
                    $softDeletedConfigurationStore = Get-AvmBicepCleanupRestCollection -Path $getPath |
                        Where-Object { $_.properties.configurationStoreId -ieq $ResourceId }

                    if ($softDeletedConfigurationStore) {

                        $purgePath = '/subscriptions/{0}/providers/Microsoft.AppConfiguration/locations/{1}/deletedConfigurationStores/{2}/purge?api-version=2021-10-01-preview' -f $subscriptionId, $softDeletedConfigurationStore.properties.location, $resourceName
                        $purgeRequestInputObject = @{
                            Method = 'POST'
                            Path   = $purgePath
                        }
                        Write-Verbose ('[*] Purging resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
                        if ($PSCmdlet.ShouldProcess(('App Configuration Store with ID [{0}]' -f $softDeletedConfigurationStore.properties.configurationStoreId), 'Purge')) {
                            $response = Invoke-AzRestMethod @purgeRequestInputObject
                            if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
                                throw [AvmProcessException]::new([string](('Purge of resource [{0}] failed with error code [{1}]' -f $ResourceId, $response.StatusCode)))
                            }
                        }
                    }
                    break
                }
                'Microsoft.KeyVault/vaults' {
                    $resourceName = $ResourceId.Split('/')[-1]

                    $matchingKeyVault = Get-AzKeyVault -InRemovedState | Where-Object { $_.resourceId -eq $ResourceId }
                    if ($RequireCompleteRemoval -and $matchingKeyVault -and $matchingKeyVault.EnablePurgeProtection) {
                        throw [AvmProcessException]::new("Purge-protected vault remains reserved: $ResourceId")
                    }
                    if ($matchingKeyVault -and -not $matchingKeyVault.EnablePurgeProtection) {
                        Write-Verbose ('[*] Purging resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
                        if ($PSCmdlet.ShouldProcess(('Key Vault with ID [{0}]' -f $matchingKeyVault.Id), 'Purge')) {
                            try {
                                $null = Remove-AzKeyVault -ResourceId $matchingKeyVault.Id -InRemovedState -Force -Location $matchingKeyVault.Location -ErrorAction 'Stop'
                            }
                            catch {
                                if (-not $RequireCompleteRemoval -and
                                    $_.Exception.Message -match 'purge protection (?:is )?enabled|PurgeProtectionEnabled') {
                                    Write-Warning ('Purge protection for key vault [{0}] enabled. Skipping. Scheduled purge date is [{1}]' -f $resourceName, $matchingKeyVault.ScheduledPurgeDate)
                                }
                                else {
                                    throw $_
                                }
                            }
                        }
                    }
                    break
                }
                'Microsoft.CognitiveServices/accounts' {
                    $resourceGroupName = $ResourceId.Split('/')[4]
                    $resourceName = $ResourceId.Split('/')[-1]

                    $matchingAccount = Get-AzCognitiveServicesAccount -InRemovedState |
                        Where-Object { $_.AccountName -ieq $resourceName -and $_.ResourceGroupName -ieq $resourceGroupName }
                    if ($matchingAccount) {
                        Write-Verbose ('[*] Purging resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
                        if ($PSCmdlet.ShouldProcess(('Cognitive services account with ID [{0}]' -f $matchingAccount.Id), 'Purge')) {
                            $null = Remove-AzCognitiveServicesAccount -InRemovedState -Force -Location $matchingAccount.Location -ResourceGroupName $resourceGroupName -Name $matchingAccount.AccountName
                        }
                    }
                    break
                }
                'Microsoft.ApiManagement/service' {
                    $subscriptionId = $ResourceId.Split('/')[2]
                    $resourceName = $ResourceId.Split('/')[-1]

                    $getPath = '/subscriptions/{0}/providers/Microsoft.ApiManagement/deletedservices?api-version=2021-08-01' -f $subscriptionId
                    $softDeletedService = Get-AvmBicepCleanupRestCollection -Path $getPath |
                        Where-Object { $_.properties.serviceId -ieq $ResourceId }

                    if ($softDeletedService) {

                        $purgePath = '/subscriptions/{0}/providers/Microsoft.ApiManagement/locations/{1}/deletedservices/{2}?api-version=2020-06-01-preview' -f $subscriptionId, $softDeletedService.location, $resourceName
                        $purgeRequestInputObject = @{
                            Method = 'DELETE'
                            Path   = $purgePath
                        }
                        Write-Verbose ('[*] Purging resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
                        if ($PSCmdlet.ShouldProcess(('API management service with ID [{0}]' -f $softDeletedService.properties.serviceId), 'Purge')) {
                            $response = Invoke-AzRestMethod @purgeRequestInputObject
                            if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
                                throw [AvmProcessException]::new(
                                    "API Management purge failed with HTTP $($response.StatusCode): $ResourceId")
                            }
                        }
                    }
                    break
                }
                'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems' {

                    $vaultId = $ResourceId.Substring(
                        0, $ResourceId.IndexOf('/backupFabrics/', [System.StringComparison]::OrdinalIgnoreCase))
                    $resourceName = $ResourceId.Split('/')[-1]
                    $vault = Invoke-AvmBicepCleanupLookup -Command 'Get-AzRecoveryServicesVaultProperty' -Parameters @{
                        VaultId = $vaultId
                    }
                    if ($null -eq $vault -or -not $PSCmdlet.ShouldProcess($ResourceId, 'Remove backup data')) {
                        break
                    }
                    $softDeleteStatus = $vault.SoftDeleteFeatureState
                    if ([string]::IsNullOrEmpty($restoreSoftDeleteStatus)) {
                        $restoreSoftDeleteStatus = $softDeleteStatus
                    }
                    $changedSoftDelete = $false
                    try {
                        if ($softDeleteStatus -ne 'Disabled') {
                            $null = Set-AzRecoveryServicesVaultProperty -VaultId $vaultId -SoftDeleteFeatureState 'Disable'
                            $changedSoftDelete = $true
                        }
                        $backupItemInputObject = @{
                            BackupManagementType = 'AzureVM'
                            WorkloadType         = 'AzureVM'
                            VaultId              = $vaultId
                            Name                 = $resourceName
                        }
                        $backupItem = Invoke-AvmBicepCleanupLookup -Command 'Get-AzRecoveryServicesBackupItem' -Parameters $backupItemInputObject
                        if ($null -ne $backupItem) {
                            if ($backupItem.DeleteState -eq 'ToBeDeleted') {
                                $null = Undo-AzRecoveryServicesBackupItemDeletion -Item $backupItem -VaultId $vaultId -Force
                            }
                            $null = Disable-AzRecoveryServicesBackupProtection -Item $backupItem -VaultId $vaultId -RemoveRecoveryPoints -Force
                        }
                    }
                    finally {
                        if ($changedSoftDelete -or $softDeleteStatus -ne $restoreSoftDeleteStatus) {
                            $null = Set-AzRecoveryServicesVaultProperty -VaultId $vaultId -SoftDeleteFeatureState $restoreSoftDeleteStatus.TrimEnd('d')
                        }
                    }
                    break
                }
                'Microsoft.Databricks/workspaces' {
                    $resourceGroupName = $ResourceId.Split('/')[4]
                    $resourceName = $ResourceId.Split('/')[-1]

                    $subscriptionId = $ResourceId.Split('/')[2]
                    $candidates = if ($ManagedResourceGroupIds.Count -gt 0) {
                        $ManagedResourceGroupIds
                    }
                    else {
                        @(
                            "/subscriptions/$subscriptionId/resourceGroups/rg-$resourceGroupName-managed"
                            "/subscriptions/$subscriptionId/resourceGroups/rg-$resourceName-managed"
                        )
                    }
                    foreach ($candidate in $candidates | Select-Object -Unique) {
                        if ($candidate -notmatch ('^/subscriptions/{0}/resourceGroups/[^/]+$' -f [regex]::Escape($subscriptionId))) {
                            throw [AvmConfigurationException]::new("Unexpected Databricks managed resource group: $candidate")
                        }
                        $group = Invoke-AvmBicepCleanupLookup -Command 'Get-AzResourceGroup' -Parameters @{
                            Name = $candidate.Split('/')[-1]
                        }
                        if ($null -eq $group) {
                            continue
                        }
                        $managedBy = [string](Get-AvmPropertyValue -InputObject $group -Name 'ManagedBy')
                        if ($managedBy -ine $ResourceId) {
                            throw [AvmProcessException]::new(
                                "Resource group '$candidate' is not managed by '$ResourceId'; it was not removed.")
                        }
                        if ($PSCmdlet.ShouldProcess($candidate, 'Remove Databricks managed resource group')) {
                            $null = Remove-AzResourceGroup -Name $candidate.Split('/')[-1] -Force
                        }
                    }
                    break
                }

            }
            if ($RequireCompleteRemoval -and (Test-AvmBicepSoftDeletedResource -ResourceId $ResourceId -Type $Type)) {
                throw [AvmProcessException]::new("Soft-deleted resource remains reserved: $ResourceId")
            }
            break
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                $removalRetryCount -ge $PostRemovalRetryLimit) {
                throw
            }
            Write-AvmLog -Message (
                "Post-removal failed for '$ResourceId': $($_.Exception.Message). Retrying ($removalRetryCount/$PostRemovalRetryLimit)."
            ) -Level Warning
            $removalRetryCount++
        }
    } while ($removalRetryCount -le $PostRemovalRetryLimit)
}
