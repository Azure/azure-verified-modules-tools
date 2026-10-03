function Remove-AvmBicepResource {

    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceId,

        [Parameter(Mandatory = $true)]
        [string] $Type
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $PSCmdlet.ShouldProcess($ResourceId, 'Remove Bicep test resource')) {
        return
    }

    if ($PSCmdlet.ShouldProcess("Possible locks on resource with ID [$ResourceId]", 'Handle')) {
        Remove-AvmBicepResourceLock -ResourceId $ResourceId -Type $Type
    }

    switch ($Type) {
        'Microsoft.Insights/diagnosticSettings' {
            $parentResourceId = $ResourceId.Substring(
                0, $ResourceId.LastIndexOf('/providers/', [System.StringComparison]::OrdinalIgnoreCase))
            $resourceName = $ResourceId.Split('/')[-1]
            if ($PSCmdlet.ShouldProcess("Diagnostic setting [$resourceName]", 'Remove')) {
                $null = Remove-AzDiagnosticSetting -ResourceId $parentResourceId -Name $resourceName
            }
            break
        }
        'Microsoft.Authorization/locks' {
            if ($PSCmdlet.ShouldProcess("Lock with ID [$ResourceId]", 'Remove')) {
                Remove-AvmBicepResourceLock -ResourceId $ResourceId -Type $Type
            }
            break
        }
        'Microsoft.KeyVault/vaults/keys' {
            $resourceName = $ResourceId.Split('/')[-1]
            Write-Verbose ('[/] Skipping resource [{0}] of type [{1}]. Reason: It is handled by different logic.' -f $resourceName, $Type) -Verbose

            break
        }
        'Microsoft.KeyVault/vaults/accessPolicies' {
            $resourceName = $ResourceId.Split('/')[-1]
            Write-Verbose ('[/] Skipping resource [{0}] of type [{1}]. Reason: It is handled by different logic.' -f $resourceName, $Type) -Verbose
            break
        }
        'Microsoft.KeyVault/managedHSMs/keys' {
            $parentName = $ResourceId.Split('/')[8]
            $resourceName = $ResourceId.Split('/')[-1]
            $hSMKeyUri = 'https://{0}.managedhsm.azure.net/keys/{1}' -f $parentName, $resourceName

            if ($PSCmdlet.ShouldProcess("Managed HSM key [$hSMKeyUri]", 'Remove')) {
                $hSMKeyApiUri = '{0}?api-version=2025-05-01' -f $hSMKeyUri
                $removeRequestInputObject = @{
                    Method = 'DELETE'
                    Uri    = $hSMKeyApiUri
                }
                $hSMKeyState = Invoke-AzRestMethod @removeRequestInputObject
                $hSMKeyStateContent = $hSMKeyState.Content | ConvertFrom-Json
                if ($hSMKeyState.StatusCode -notlike '2*') {
                    throw [AvmProcessException]::new([string](('{0} : {1}' -f $hSMKeyStateContent.error.code, $hSMKeyStateContent.error.message)))
                }
            }
            break
        }
        'Microsoft.ServiceBus/namespaces/authorizationRules' {
            if ($ResourceId.Split('/')[-1] -eq 'RootManageSharedAccessKey') {
                Write-Verbose ('[/] Skipping resource [RootManageSharedAccessKey] of type [{0}]. Reason: The Service Bus''s default authorization key cannot be removed' -f $Type) -Verbose
            }
            else {
                if ($PSCmdlet.ShouldProcess("Resource with ID [$ResourceId]", 'Remove')) {
                    $null = Remove-AzResource -ResourceId $ResourceId -Force -ErrorAction 'Stop'
                }
            }
            break
        }
        'Microsoft.Compute/diskEncryptionSets' {

            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]

            $diskEncryptionSet = Get-AzDiskEncryptionSet -Name $resourceName -ResourceGroupName $resourceGroupName
            $keyVaultResourceId = $diskEncryptionSet.ActiveKey.SourceVault.Id
            $keyVaultName = $keyVaultResourceId.Split('/')[-1]
            $objectId = $diskEncryptionSet.Identity.PrincipalId

            if ($PSCmdlet.ShouldProcess(('Access policy [{0}] from key vault [{1}]' -f $objectId, $keyVaultName), 'Remove')) {
                $null = Remove-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $objectId
            }

            if ($PSCmdlet.ShouldProcess("Resource with ID [$ResourceId]", 'Remove')) {
                $null = Remove-AzResource -ResourceId $ResourceId -Force -ErrorAction 'Stop'
            }
            break
        }
        'Microsoft.RecoveryServices/vaults/backupstorageconfig' {

            break
        }
        'Microsoft.Authorization/roleAssignments' {
            $idElem = $ResourceId.Split('/')
            $scope = $idElem[0..($idElem.Count - 5)] -join '/'
            if ([string]::IsNullOrEmpty($scope)) { $scope = '/' }
            $roleAssignmentsOnScope = Get-AzRoleAssignment -Scope $scope
            if ($PSCmdlet.ShouldProcess($ResourceId, 'Remove role assignment')) {
                $null = $roleAssignmentsOnScope |
                    Where-Object { $_.RoleAssignmentId -ieq $ResourceId } |
                    Remove-AzRoleAssignment
            }
            break
        }
        'Microsoft.Authorization/roleEligibilityScheduleRequests' {
            $idElem = $ResourceId.Split('/')
            $scope = $idElem[0..($idElem.Count - 5)] -join '/'
            if ([string]::IsNullOrEmpty($scope)) { $scope = '/' }
            $pimRequestName = $idElem[-1]
            $pimRoleAssignment = Get-AzRoleEligibilityScheduleRequest -Scope $scope -Name $pimRequestName
            if ($pimRoleAssignment) {
                $pimRoleAssignmentPrinicpalId = $pimRoleAssignment.PrincipalId
                $pimRoleAssignmentRoleDefinitionId = $pimRoleAssignment.RoleDefinitionId
                $guid = New-Guid

                Write-Verbose 'Waiting for 5 minutes before removing PIM role assignment' -Verbose
                Start-Sleep -Seconds 300

                $removalInputObject = @{
                    Name             = $guid
                    Scope            = $scope
                    PrincipalId      = $pimRoleAssignmentPrinicpalId
                    RequestType      = 'AdminRemove'
                    RoleDefinitionId = $pimRoleAssignmentRoleDefinitionId
                }
                if ($PSCmdlet.ShouldProcess($ResourceId, 'Remove role eligibility')) {
                    $null = New-AzRoleEligibilityScheduleRequest @removalInputObject
                }

            }
            break
        }
        'Microsoft.Authorization/roleAssignmentScheduleRequests' {
            $idElem = $ResourceId.Split('/')
            $scope = $idElem[0..($idElem.Count - 5)] -join '/'
            if ([string]::IsNullOrEmpty($scope)) { $scope = '/' }
            $pimRequestName = $idElem[-1]
            $pimRoleAssignment = Get-AzRoleAssignmentScheduleRequest -Scope $scope -Name $pimRequestName
            if ($pimRoleAssignment) {
                $pimRoleAssignmentPrinicpalId = $pimRoleAssignment.PrincipalId
                $pimRoleAssignmentRoleDefinitionId = $pimRoleAssignment.RoleDefinitionId
                $guid = New-Guid

                Write-Verbose 'Waiting for 5 minutes before removing PIM role assignment' -Verbose
                Start-Sleep -Seconds 300

                $removalInputObject = @{
                    Name             = $guid
                    Scope            = $scope
                    PrincipalId      = $pimRoleAssignmentPrinicpalId
                    RequestType      = 'AdminRemove'
                    RoleDefinitionId = $pimRoleAssignmentRoleDefinitionId
                }
                if ($PSCmdlet.ShouldProcess($ResourceId, 'Remove scheduled role assignment')) {
                    $null = New-AzRoleAssignmentScheduleRequest @removalInputObject
                }
            }
            break
        }
        'Microsoft.Cdn/profiles' {

            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]
            $cdnProfile = Invoke-AvmBicepCleanupCli -ArgumentList @(
                'cdn', 'profile', 'show', '--resource-group', $resourceGroupName, '--name', $resourceName
            ) -AllowNotFound
            if ($cdnProfile) {
                if ($PSCmdlet.ShouldProcess("Resource with ID [$ResourceId]", 'Remove')) {
                    $null = Invoke-AvmBicepCleanupCli -ArgumentList @(
                        'cdn', 'profile', 'delete', '--resource-group', $resourceGroupName, '--name', $resourceName
                    )
                }
            }
            else {
                Write-Warning "Unable to find CDN profile [$resourceName] in resource group [$resourceGroupName]"
            }
            break
        }
        'Microsoft.RecoveryServices/vaults' {

            if ((Get-AzRecoveryServicesVaultProperty -VaultId $ResourceId).SoftDeleteFeatureState -ne 'Disabled') {
                if ($PSCmdlet.ShouldProcess(('Soft-delete on RSV [{0}]' -f $ResourceId), 'Set')) {
                    $null = Set-AzRecoveryServicesVaultProperty -VaultId $ResourceId -SoftDeleteFeatureState 'Disable'
                }
            }

            $backupItems = Get-AzRecoveryServicesBackupItem -BackupManagementType 'AzureVM' -WorkloadType 'AzureVM' -VaultId $ResourceId
            foreach ($backupItem in $backupItems) {
                Write-Verbose ('Removing Backup item [{0}] from RSV [{1}]' -f $backupItem.Name, $ResourceId) -Verbose

                if ($backupItem.DeleteState -eq 'ToBeDeleted') {
                    if ($PSCmdlet.ShouldProcess('Soft-deleted backup data removal', 'Undo')) {
                        $null = Undo-AzRecoveryServicesBackupItemDeletion -Item $backupItem -VaultId $ResourceId -Force
                    }
                }

                if ($PSCmdlet.ShouldProcess(('Backup item [{0}] from RSV [{1}]' -f $backupItem.Name, $ResourceId), 'Remove')) {
                    $null = Disable-AzRecoveryServicesBackupProtection -Item $backupItem -VaultId $ResourceId -RemoveRecoveryPoints -Force
                }
            }

            if ($PSCmdlet.ShouldProcess("Resource with ID [$ResourceId]", 'Remove')) {
                $null = Remove-AzResource -ResourceId $ResourceId -Force -ErrorAction 'Stop'
            }
            break
        }
        'Microsoft.DataProtection/backupVaults' {

            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]
            $vault = Get-AzDataProtectionBackupVault -ResourceGroupName $resourceGroupName -VaultName $resourceName

            if ($vault.ImmutabilityState -ne 'Disabled') {
                Write-Verbose ('    [-] Disabling immutability on vault [{0}]' -f $resourceName) -Verbose
                if ($PSCmdlet.ShouldProcess(('Immutability on vault [{0}]' -f $resourceName), 'Update')) {
                    $null = Update-AzDataProtectionBackupVault -ResourceGroupName $resourceGroupName -VaultName $resourceName -ImmutabilityState Disabled
                }
            }

            if ($vault.SoftDeleteState -ne 'Off') {
                Write-Verbose ('    [-] Disabling soft-deletion on vault [{0}]' -f $resourceName) -Verbose
                if ($PSCmdlet.ShouldProcess(('Soft-delete on vault [{0}]' -f $resourceName), 'Update')) {
                    $null = Update-AzDataProtectionBackupVault -ResourceGroupName $resourceGroupName -VaultName $resourceName -SoftDeleteState Off
                }
            }

            $softDeletedBackupInstances = Get-AzDataProtectionSoftDeletedBackupInstance -ResourceGroupName $resourceGroupName -VaultName $resourceName
            foreach ($softDeletedBackupInstance in $softDeletedBackupInstances) {
                Write-Verbose ('    [-] Removing Backup instance soft deletion [{0}] from vault [{1}]' -f $softDeletedBackupInstance.Name, $resourceName) -Verbose
                if ($PSCmdlet.ShouldProcess(('Soft deletion on backup instance [{0}] from vault [{1}]' -f $softDeletedBackupInstance.Name, $resourceName), 'Undo')) {
                    $null = Undo-AzDataProtectionBackupInstanceDeletion -ResourceGroupName $resourceGroupName -VaultName $resourceName -BackupInstanceName $softDeletedBackupInstance.name
                }
            }

            $backupInstances = Get-AzDataProtectionBackupInstance -ResourceGroupName $resourceGroupName -VaultName $resourceName
            foreach ($backupInstance in $backupInstances) {
                Write-Verbose ('    [-] Removing Backup instance [{0}] from vault [{1}]' -f $backupInstance.Name, $resourceName) -Verbose
                if ($PSCmdlet.ShouldProcess(('Backup instance [{0}] from vault [{1}]' -f $backupInstance.Name, $resourceName), 'Remove')) {
                    $null = Remove-AzDataProtectionBackupInstance -ResourceGroupName $resourceGroupName -VaultName $resourceName -Name $backupInstance.name
                }
            }

            $backupPolicies = Get-AzDataProtectionBackupPolicy -ResourceGroupName $resourceGroupName -VaultName $resourceName
            foreach ($backupPolicy in $backupPolicies) {
                Write-Verbose ('    [-] Removing Backup policy [{0}] from vault [{1}]' -f $backupPolicy.Name, $resourceName) -Verbose
                if ($PSCmdlet.ShouldProcess(('Backup instance [{0}] from vault [{1}]' -f $backupPolicy.Name, $resourceName), 'Remove')) {
                    $null = Remove-AzDataProtectionBackupPolicy -ResourceGroupName $resourceGroupName -VaultName $resourceName -Name $backupPolicy.name
                }
            }

            Write-Verbose ('    [-] Removing Backup vault [{0}]' -f $resourceName) -Verbose
            if ($PSCmdlet.ShouldProcess("Backup vault with ID [$ResourceId]", 'Remove')) {
                $null = Remove-AzDataProtectionBackupVault -ResourceGroupName $resourceGroupName -VaultName $resourceName
            }
            break
        }
        'Microsoft.OperationalInsights/workspaces' {

            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]
            $subscriptionId = $ResourceId.Split('/')[2]

            $workspaceApiPath = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.OperationalInsights/workspaces/{2}?api-version=2025-02-01' -f $subscriptionId, $resourceGroupName, $resourceName
            $getWorkspaceStateInputObject = @{
                Method = 'GET'
                Path   = $workspaceApiPath
            }
            $workspaceState = Invoke-AzRestMethod @getWorkspaceStateInputObject
            $workspaceStateContent = $workspaceState.Content | ConvertFrom-Json
            if ($workspaceState.StatusCode -notlike '2*') {
                throw [AvmProcessException]::new([string](('{0} : {1}' -f $workspaceStateContent.error.code, $workspaceStateContent.error.message)))
            }

            $replication = Get-AvmPropertyValue -InputObject $workspaceStateContent.properties -Name 'replication'
            if (Get-AvmPropertyValue -InputObject $replication -Name 'enabled') {
                $retryCount = 1
                $retryLimit = 90
                $retryInterval = 60
                $replicationCreated = [DateTime]$workspaceStateContent.properties.replication.createdDate
                $replicationFullyProvisioned = $false

                do {

                    if ([DateTime]::UtcNow -lt $replicationCreated.AddHours(1)) {
                        $timeLeft = [int]($replicationCreated.AddHours(1) - [DateTime]::UtcNow).TotalSeconds
                        Write-Verbose ('    [progress] Waiting {0} minutes to ensure at least 1 hour has passed since replication creation time [{1}] (UTC).' -f [int]($timeLeft / 60), $replicationCreated) -Verbose
                        Start-Sleep -Seconds ([int]$timeLeft + 10)
                        $retryCount++
                        continue
                    }

                    $getWorkspaceState = Invoke-AzRestMethod @getWorkspaceStateInputObject
                    $workspaceStateContent = $getWorkspaceState.Content | ConvertFrom-Json
                    if ($getWorkspaceState.StatusCode -notlike '2*') {
                        throw [AvmProcessException]::new([string](('{0} : {1}' -f $workspaceStateContent.error.code, $workspaceStateContent.error.message)))
                    }

                    if ($workspaceStateContent.properties.replication.provisioningState -eq 'Succeeded') {
                        Write-Verbose ('    [progress] Workspace replication is in a state that allows disabling.') -Verbose
                        $replicationFullyProvisioned = $true
                        break
                    }
                    else {
                        $replicationFullyProvisioned = $false
                        Write-Verbose ('    [progress] Waiting {0} seconds for workspace replication to finish provisioning. [{1}/{2}]' -f $retryInterval, $retryCount, $retryLimit) -Verbose
                        Start-Sleep -Seconds $retryInterval
                        $retryCount++
                    }
                } while (-not $replicationFullyProvisioned -and $retryCount -lt $retryLimit)

                if (-not $replicationFullyProvisioned) {
                    throw [AvmProcessException]::new("Workspace replication did not finish provisioning: $ResourceId")
                }

                $disableReplicationInputObject = @{
                    Method  = 'PUT'
                    Path    = $workspaceApiPath
                    Payload = @{
                        properties = @{
                            replication = @{
                                enabled = $false
                            }
                        }
                        location   = $workspaceStateContent.location
                    } | ConvertTo-Json -Depth 10
                }
                Write-Verbose ('[*] Disabling workspace replication for resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
                if ($PSCmdlet.ShouldProcess("Log Analytics Workspace [$resourceName]", 'Disable replication')) {
                    $disableReplicationResponse = Invoke-AzRestMethod @disableReplicationInputObject
                    if ($disableReplicationResponse.StatusCode -notlike '2*') {
                        $responseContent = $disableReplicationResponse.Content | ConvertFrom-Json
                        throw [AvmProcessException]::new([string](('{0} : {1}' -f $responseContent.error.code, $responseContent.error.message)))
                    }

                    $retryCount = 1
                    $retryLimit = 240
                    $retryInterval = 15
                    do {
                        $getWorkspaceState = Invoke-AzRestMethod @getWorkspaceStateInputObject
                        $workspaceStateContent = $getWorkspaceState.Content | ConvertFrom-Json
                        if ($getWorkspaceState.StatusCode -notlike '2*') {
                            throw [AvmProcessException]::new([string](('{0} : {1}' -f $workspaceStateContent.error.code, $workspaceStateContent.error.message)))
                        }

                        if (-not $workspaceStateContent.properties.replication.enabled -and $workspaceStateContent.properties.replication.provisioningState -eq 'Succeeded') {
                            Write-Verbose ('    [progress] Workspace replication is disabled.') -Verbose
                            break
                        }
                        else {
                            Write-Verbose ('    [progress] Waiting {0} seconds for workspace replication to be disabled. [{1}/{2}]' -f $retryInterval, $retryCount, $retryLimit) -Verbose
                            Start-Sleep -Seconds $retryInterval
                            $retryCount++
                        }
                    } while (($workspaceStateContent.properties.replication.enabled -or $workspaceStateContent.properties.replication.provisioningState -ne 'Succeeded') -and $retryCount -lt $retryLimit)
                    Start-Sleep -Seconds 30

                    if ($workspaceStateContent.properties.replication.enabled -or
                        $workspaceStateContent.properties.replication.provisioningState -ne 'Succeeded') {
                        throw [AvmProcessException]::new("Workspace replication could not be disabled: $ResourceId")
                    }
                }
            }

            if ($PSCmdlet.ShouldProcess("Log Analytics Workspace [$resourceName]", 'Remove')) {
                Write-Verbose ('[*] Purging resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
                $null = Remove-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroupName -Name $resourceName -Force -ForceDelete
            }
            break
        }
        'Microsoft.VirtualMachineImages/imageTemplates' {

            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]
            $subscriptionId = $ResourceId.Split('/')[2]

            if ($PSCmdlet.ShouldProcess("Image Template [$resourceName]", 'Remove')) {

                $removeRequestInputObject = @{
                    Method = 'DELETE'
                    Path   = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.VirtualMachineImages/imageTemplates/{2}?api-version=2022-07-01' -f $subscriptionId, $resourceGroupName, $resourceName
                }
                $removalResponse = Invoke-AzRestMethod @removeRequestInputObject
                if ($removalResponse.StatusCode -notlike '2*') {
                    $responseContent = $removalResponse.Content | ConvertFrom-Json
                    throw [AvmProcessException]::new([string](('{0} : {1}' -f $responseContent.error.code, $responseContent.error.message)))
                }

                $retryCount = 0
                $retryLimit = 240
                $retryInterval = 15
                do {
                    $retryCount++
                    $getRequestInputObject = @{
                        Method = 'GET'
                        Path   = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.VirtualMachineImages/imageTemplates/{2}?api-version=2022-07-01' -f $subscriptionId, $resourceGroupName, $resourceName
                    }
                    $getResponse = Invoke-AzRestMethod @getRequestInputObject

                    if ($getResponse.StatusCode -eq 400) {

                        throw [AvmProcessException]::new([string](($getResponse.Content | ConvertFrom-Json).error.message))
                    }
                    elseif ($getResponse.StatusCode -eq 404) {

                        $templateExists = $false
                    }
                    elseif ($getResponse.StatusCode -eq '200') {

                        $templateExists = $true
                        Write-Verbose ('    [progress] Waiting {0} seconds for Image Template to be removed. [{1}/{2}]' -f $retryInterval, $retryCount, $retryLimit) -Verbose
                        if ($retryCount -lt $retryLimit) {
                            Start-Sleep -Seconds $retryInterval
                        }
                    }
                    else {
                        throw [AvmProcessException]::new(
                            "Image template lookup failed with HTTP $($getResponse.StatusCode): $ResourceId")
                    }
                } while ($templateExists -and $retryCount -lt $retryLimit)

                if ($templateExists) {
                    throw [AvmProcessException]::new("Image template deletion did not finish: $ResourceId")
                }
            }
            break
        }
        'Microsoft.MachineLearningServices/workspaces' {
            $subscriptionId = $ResourceId.Split('/')[2]
            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]

            $purgePath = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.MachineLearningServices/workspaces/{2}?api-version=2023-06-01-preview&forceToPurge=true' -f $subscriptionId, $resourceGroupName, $resourceName
            $purgeRequestInputObject = @{
                Method = 'DELETE'
                Path   = $purgePath
            }
            Write-Verbose ('[*] Purging resource [{0}] of type [{1}]' -f $resourceName, $Type) -Verbose
            if ($PSCmdlet.ShouldProcess("Machine Learning Workspace [$resourceName]", 'Purge')) {
                $purgeResource = Invoke-AzRestMethod @purgeRequestInputObject
                if ($purgeResource.StatusCode -notlike '2*') {
                    $responseContent = $purgeResource.Content | ConvertFrom-Json
                    throw [AvmProcessException]::new([string](('{0} : {1}' -f $responseContent.error.code, $responseContent.error.message)))
                }

                $retryCount = 0
                $retryLimit = 240
                $retryInterval = 15
                do {
                    $retryCount++
                    if ($retryCount -ge $retryLimit) {
                        throw [AvmProcessException]::new("Machine Learning workspace purge did not finish: $ResourceId")
                    }
                    Write-Verbose ('    [progress] Waiting {0} seconds for workspace to be purged.' -f $retryInterval) -Verbose
                    Start-Sleep -Seconds $retryInterval
                    $workspace = @(Invoke-AvmBicepCleanupLookup -Command 'Get-AzMLWorkspace' -Parameters @{
                            Name              = $resourceName
                            ResourceGroupName = $resourceGroupName
                            SubscriptionId    = $subscriptionId
                        })
                    $workspaceExists = @($workspace | Where-Object { $null -ne $_ }).Count -gt 0
                } while ($workspaceExists)
            }
            break
        }
        { $PSItem -eq 'Microsoft.Subscription/aliases' -and $ResourceId -like '*dep-sub-blzv-tests*' } {
            $subscriptionName = $ResourceId.Split('/')[4]
            $subscriptions = @(Get-AzSubscription | Where-Object { $_.Name -eq $subscriptionName })
            if ($subscriptions.Count -ne 1) {
                throw [AvmProcessException]::new("Expected one subscription for alias '$subscriptionName'; found $($subscriptions.Count).")
            }
            $subscription = $subscriptions[0]
            $subscriptionId = $subscription.Id
            $subscriptionState = $subscription.State

            $null = Set-AzContext -SubscriptionId $subscriptionId -Scope Process -ErrorAction Stop

            if (Invoke-AvmBicepCleanupLookup -Command 'Get-AzResourceGroup' -Parameters @{ Name = 'NetworkWatcherRG' }) {
                if ($PSCmdlet.ShouldProcess('Resource Group [NetworkWatcherRG]', 'Remove')) {
                    $null = Remove-AzResourceGroup -Name 'NetworkWatcherRG' -Force
                }
            }

            if (-not (Invoke-AvmBicepCleanupLookup -Command 'Get-AzManagementGroupSubscription' -Parameters @{
                        GroupName      = 'bicep-lz-vending-automation-decom'
                        SubscriptionId = $subscriptionId
                    })) {
                Write-Verbose ('[*] Moving resource [{0}] of type [{1}] to management group: bicep-lz-vending-automation-decom' -f $subscriptionName, $Type) -Verbose
                if ($PSCmdlet.ShouldProcess("Subscription [$subscriptionName] to Management Group: bicep-lz-vending-automation-decom", 'Move')) {
                    $null = New-AzManagementGroupSubscription -GroupName 'bicep-lz-vending-automation-decom' -SubscriptionId $subscriptionId
                }
            }

            if ($subscriptionState -eq 'Enabled') {
                Write-Verbose ('[*] Disabling resource [{0}] of type [{1}]' -f $subscriptionName, $Type) -Verbose
                if ($PSCmdlet.ShouldProcess("Subscription [$subscriptionName]", 'Remove')) {
                    $null = Disable-AzSubscription -SubscriptionId $subscriptionId -Confirm:$false
                }
            }
            break
        }
        'Microsoft.ApiManagement/service' {
            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]
            $subscriptionId = $ResourceId.Split('/')[2]

            $apimService = Invoke-AvmBicepCleanupCli -ArgumentList @(
                'apim', 'show', '--resource-group', $resourceGroupName, '--name', $resourceName
            ) -AllowNotFound
            if ($apimService) {
                $apimLocation = ($apimService | ConvertFrom-Json).location

                $retryCount = 0
                $retryLimit = 30
                $retryInterval = 60
                $deleteSucceeded = $false

                do {
                    $retryCount++
                    Write-Verbose ('[*] Removing API Management service [{0}] from resource group [{1}] (attempt [{2}/{3}])' -f $resourceName, $resourceGroupName, $retryCount, $retryLimit) -Verbose

                    if ($PSCmdlet.ShouldProcess("API Management service [$resourceName]", 'Remove')) {
                        $deleteOutput = Invoke-AvmBicepCleanupCli -ArgumentList @(
                            'apim', 'delete', '--resource-group', $resourceGroupName, '--name', $resourceName, '--yes'
                        ) -IgnoreExitCode

                        if ($deleteOutput.ExitCode -eq 0) {
                            $deleteSucceeded = $true
                            Write-Verbose ('[progress] Successfully initiated deletion of API Management service [{0}]' -f $resourceName) -Verbose
                        }
                        else {
                            $deleteOutputString = $deleteOutput.StdErr
                            if ($deleteOutputString -match 'ServiceLocked|transitioning') {
                                Write-Verbose ('    [progress] API Management service [{0}] is transitioning. Waiting {1} seconds before retrying. [{2}/{3}]' -f $resourceName, $retryInterval, $retryCount, $retryLimit) -Verbose
                                Start-Sleep -Seconds $retryInterval
                            }
                            else {
                                throw [AvmProcessException]::new(
                                    "Failed to delete API Management service '$resourceName': $deleteOutputString")
                            }
                        }
                    }
                    else {
                        break
                    }
                } while (-not $deleteSucceeded -and $retryCount -lt $retryLimit)

                if (-not $deleteSucceeded) {
                    if ($retryCount -ge $retryLimit) {
                        throw [AvmProcessException]::new(
                            "Failed to delete API Management service '$resourceName' after $retryCount attempts.")
                    }
                    break
                }

                $retryCount = 0
                $retryLimit = 60
                $retryInterval = 30
                $serviceSoftDeleted = $false

                do {
                    $retryCount++
                    $existingService = Invoke-AvmBicepCleanupCli -ArgumentList @(
                        'apim', 'show', '--resource-group', $resourceGroupName, '--name', $resourceName
                    ) -AllowNotFound
                    if (-not $existingService) {
                        $serviceSoftDeleted = $true
                        Write-Verbose ('[progress] API Management service [{0}] has been soft-deleted.' -f $resourceName) -Verbose
                    }
                    else {
                        Write-Verbose ('    [progress] Waiting {0} seconds for API Management service [{1}] to be soft-deleted. [{2}/{3}]' -f $retryInterval, $resourceName, $retryCount, $retryLimit) -Verbose
                        Start-Sleep -Seconds $retryInterval
                    }
                } while (-not $serviceSoftDeleted -and $retryCount -lt $retryLimit)

                if (-not $serviceSoftDeleted) {
                    throw [AvmProcessException]::new(
                        "API Management service '$resourceName' did not finish soft deletion.")
                }

                $softDeletedService = Invoke-AvmBicepCleanupCli -ArgumentList @(
                    'apim', 'deletedservice', 'show', '--service-name', $resourceName, '--location', $apimLocation
                ) -AllowNotFound
                if ($softDeletedService) {
                    Write-Verbose ('[*] Purging soft-deleted API Management service [{0}] in location [{1}]' -f $resourceName, $apimLocation) -Verbose
                    if ($PSCmdlet.ShouldProcess("API Management service [$resourceName]", 'Purge')) {
                        $null = Invoke-AvmBicepCleanupCli -ArgumentList @(
                            'apim', 'deletedservice', 'purge', '--service-name', $resourceName, '--location', $apimLocation
                        )
                    }
                }
                else {
                    Write-Verbose ('[/] No soft-deleted API Management service [{0}] found in location [{1}]. Skipping purge.' -f $resourceName, $apimLocation) -Verbose
                }
            }
            else {

                Write-Verbose ('[/] API Management service [{0}] not found in resource group [{1}]. Checking for soft-deleted instance.' -f $resourceName, $resourceGroupName) -Verbose
                $softDeletedServices = @(Get-AvmBicepCleanupRestCollection -Path (
                        "/subscriptions/$subscriptionId/providers/Microsoft.ApiManagement/deletedservices?api-version=2021-08-01"
                    ))
                if ($softDeletedServices) {
                    $matchingDeleted = $softDeletedServices |
                        Where-Object { $_.properties.serviceId -ieq $ResourceId }
                    if ($matchingDeleted) {
                        $apimLocation = $matchingDeleted.location
                        Write-Verbose ('[*] Purging soft-deleted API Management service [{0}] in location [{1}]' -f $resourceName, $apimLocation) -Verbose
                        if ($PSCmdlet.ShouldProcess("API Management service [$resourceName]", 'Purge')) {
                            $null = Invoke-AvmBicepCleanupCli -ArgumentList @(
                                'apim', 'deletedservice', 'purge', '--service-name', $resourceName, '--location', $apimLocation
                            )
                        }
                    }
                    else {
                        Write-Warning "Unable to find API Management service [$resourceName] (active or soft-deleted)"
                    }
                }
            }
            break
        }
        'Microsoft.Network/expressRouteGateways' {
            $resourceGroupName = $ResourceId.Split('/')[4]
            $resourceName = $ResourceId.Split('/')[-1]
            if ($PSCmdlet.ShouldProcess("Express Route Gateway [$resourceName]", 'Remove')) {

                $null = Remove-AzExpressRouteGateway -ResourceGroupName $resourceGroupName -Name $resourceName -Force -ErrorAction 'Stop'
                $retryCount = 0
                $maxRetries = 60
                do {
                    $gateway = Invoke-AvmBicepCleanupLookup -Command 'Get-AzExpressRouteGateway' -Parameters @{
                        ResourceGroupName = $resourceGroupName
                        Name              = $resourceName
                    }
                    if ($gateway) {
                        $retryCount++
                        Write-Verbose ("Express Route Gateway [$resourceName] still deleting. Waiting 30 seconds. [{0}/{1}]" -f $retryCount, $maxRetries) -Verbose
                        Start-Sleep -Seconds 30
                    }
                } while ($gateway -and $retryCount -lt $maxRetries)
                if ($gateway) {
                    throw [AvmProcessException]::new([string]("Express Route Gateway [$resourceName] did not finish deleting within the expected time."))
                }
            }
            break
        }

        default {
            if ($PSCmdlet.ShouldProcess("Resource with ID [$ResourceId]", 'Remove')) {
                $null = Remove-AzResource -ResourceId $ResourceId -Force -ErrorAction 'Stop'
            }
        }
    }
}
