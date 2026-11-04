function Remove-AvmBicepResource {

    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceId,

        [Parameter(Mandatory = $true)]
        [string] $Type,

        [string] $SubscriptionCleanupManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Type -ieq 'Microsoft.Authorization/roleAssignments') {
        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($ResourceId)
        $assignmentId = [guid]::Empty
        if ($resource.type -ine $Type -or
            -not [guid]::TryParseExact($ResourceId.Split('/')[-1], 'D', [ref]$assignmentId)) {
            throw [AvmConfigurationException]::new('Role-assignment cleanup requires an exact ARM role assignment ID ending in a GUID.')
        }
    }
    $managementGroupName = ''
    if ($Type -ieq 'Microsoft.Management/managementGroups') {
        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($ResourceId)
        if ($resource.type -ine $Type -or
            $ResourceId -notmatch '^/providers/Microsoft\.Management/managementGroups/[^/]+$') {
            throw [AvmConfigurationException]::new('Management-group cleanup requires an exact management group ID.')
        }
        $managementGroupName = $ResourceId.Split('/')[-1]
    }
    if (-not $PSCmdlet.ShouldProcess($ResourceId, 'Remove Bicep test resource')) {
        return
    }

    if ($Type -ine 'Microsoft.Management/managementGroups' -and
        $PSCmdlet.ShouldProcess("Possible locks on resource with ID [$ResourceId]", 'Handle')) {
        Remove-AvmBicepResourceLock -ResourceId $ResourceId -Type $Type
    }

    switch ($Type) {
        'Microsoft.Management/managementGroups' {
            if ($PSCmdlet.ShouldProcess("Management group [$managementGroupName]", 'Remove')) {
                $null = Remove-AzManagementGroup -GroupName $managementGroupName -ErrorAction Stop
            }
            break
        }
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
            Write-AvmLog -Level Info -Message "Skipped ${resourceName}: handled separately."

            break
        }
        'Microsoft.KeyVault/vaults/accessPolicies' {
            $resourceName = $ResourceId.Split('/')[-1]
            Write-AvmLog -Level Info -Message "Skipped ${resourceName}: handled separately."
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
                Write-AvmLog -Level Info -Message 'Skipped RootManageSharedAccessKey: the default authorization key cannot be removed.'
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
            if ($PSCmdlet.ShouldProcess($ResourceId, 'Remove role assignment')) {
                $response = Invoke-AzRestMethod -Method DELETE -Path "$($ResourceId)?api-version=2022-04-01" -ErrorAction Stop
                $status = Get-AvmPropertyValue -InputObject $response -Name StatusCode -NoEnumerate
                if (($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or
                    $status -notin @(200, 204, 404)) {
                    throw [AvmProcessException]::new('ARM did not confirm removal or absence of the recorded role assignment.')
                }
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

                Write-AvmLog -Level Info -Message 'Waiting 5 minutes before removing the PIM role assignment.'
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

                Write-AvmLog -Level Info -Message 'Waiting 5 minutes before removing the PIM role assignment.'
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
                Write-AvmLog -Level Info -Message "Removing backup item $($backupItem.Name) from $ResourceId."

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
                Write-AvmLog -Level Info -Message "Disabling immutability on vault $resourceName."
                if ($PSCmdlet.ShouldProcess(('Immutability on vault [{0}]' -f $resourceName), 'Update')) {
                    $null = Update-AzDataProtectionBackupVault -ResourceGroupName $resourceGroupName -VaultName $resourceName -ImmutabilityState Disabled
                }
            }

            if ($vault.SoftDeleteState -ne 'Off') {
                Write-AvmLog -Level Info -Message "Disabling soft deletion on vault $resourceName."
                if ($PSCmdlet.ShouldProcess(('Soft-delete on vault [{0}]' -f $resourceName), 'Update')) {
                    $null = Update-AzDataProtectionBackupVault -ResourceGroupName $resourceGroupName -VaultName $resourceName -SoftDeleteState Off
                }
            }

            $softDeletedBackupInstances = Get-AzDataProtectionSoftDeletedBackupInstance -ResourceGroupName $resourceGroupName -VaultName $resourceName
            foreach ($softDeletedBackupInstance in $softDeletedBackupInstances) {
                Write-AvmLog -Level Info -Message "Undoing soft deletion of backup instance $($softDeletedBackupInstance.Name) on vault $resourceName."
                if ($PSCmdlet.ShouldProcess(('Soft deletion on backup instance [{0}] from vault [{1}]' -f $softDeletedBackupInstance.Name, $resourceName), 'Undo')) {
                    $null = Undo-AzDataProtectionBackupInstanceDeletion -ResourceGroupName $resourceGroupName -VaultName $resourceName -BackupInstanceName $softDeletedBackupInstance.name
                }
            }

            $backupInstances = Get-AzDataProtectionBackupInstance -ResourceGroupName $resourceGroupName -VaultName $resourceName
            foreach ($backupInstance in $backupInstances) {
                Write-AvmLog -Level Info -Message "Removing backup instance $($backupInstance.Name) from vault $resourceName."
                if ($PSCmdlet.ShouldProcess(('Backup instance [{0}] from vault [{1}]' -f $backupInstance.Name, $resourceName), 'Remove')) {
                    $null = Remove-AzDataProtectionBackupInstance -ResourceGroupName $resourceGroupName -VaultName $resourceName -Name $backupInstance.name
                }
            }

            $backupPolicies = Get-AzDataProtectionBackupPolicy -ResourceGroupName $resourceGroupName -VaultName $resourceName
            foreach ($backupPolicy in $backupPolicies) {
                Write-AvmLog -Level Info -Message "Removing backup policy $($backupPolicy.Name) from vault $resourceName."
                if ($PSCmdlet.ShouldProcess(('Backup instance [{0}] from vault [{1}]' -f $backupPolicy.Name, $resourceName), 'Remove')) {
                    $null = Remove-AzDataProtectionBackupPolicy -ResourceGroupName $resourceGroupName -VaultName $resourceName -Name $backupPolicy.name
                }
            }

            Write-AvmLog -Level Info -Message "Removing backup vault $resourceName."
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
                        Write-AvmLog -Level Info -Message "Waiting $([int]($timeLeft / 60)) minutes for workspace replication to reach one hour."
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
                        Write-AvmLog -Level Info -Message 'Workspace replication is ready to disable.'
                        $replicationFullyProvisioned = $true
                        break
                    }
                    else {
                        $replicationFullyProvisioned = $false
                        Write-AvmLog -Level Info -Message "Waiting $retryInterval seconds for workspace replication to finish provisioning ($retryCount/$retryLimit)."
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
                Write-AvmLog -Level Info -Message "Disabling workspace replication for $resourceName."
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
                            Write-AvmLog -Level Info -Message 'Workspace replication is disabled.'
                            break
                        }
                        else {
                            Write-AvmLog -Level Info -Message "Waiting $retryInterval seconds for workspace replication to be disabled ($retryCount/$retryLimit)."
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
                Write-AvmLog -Level Info -Message "Purging workspace $resourceName..."
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
                        Write-AvmLog -Level Info -Message "Waiting $retryInterval seconds for the image template to be removed ($retryCount/$retryLimit)."
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
            Write-AvmLog -Level Info -Message "Purging Machine Learning workspace $resourceName..."
            if ($PSCmdlet.ShouldProcess("Machine Learning Workspace [$resourceName]", 'Purge')) {
                $purgeResource = Invoke-AzRestMethod @purgeRequestInputObject
                if ($purgeResource.StatusCode -notlike '2*') {
                    $responseContent = $purgeResource.Content | ConvertFrom-Json
                    throw [AvmProcessException]::new([string](('{0} : {1}' -f $responseContent.error.code, $responseContent.error.message)))
                }
                Write-AvmLog -Level Info -Message "Requested purge of Machine Learning workspace $resourceName (HTTP $($purgeResource.StatusCode))."

                $retryCount = 0
                $retryLimit = 240
                $retryInterval = 15
                do {
                    $retryCount++
                    if ($retryCount -ge $retryLimit) {
                        throw [AvmProcessException]::new("Machine Learning workspace purge did not finish: $ResourceId")
                    }
                    Write-AvmLog -Level Info -Message "Waiting $retryInterval seconds for workspace $resourceName to be purged."
                    Start-Sleep -Seconds $retryInterval
                    $workspace = @(Invoke-AvmBicepCleanupLookup -Command 'Get-AzMLWorkspace' -Parameters @{
                            Name              = $resourceName
                            ResourceGroupName = $resourceGroupName
                            SubscriptionId    = $subscriptionId
                        })
                    $workspaceExists = @($workspace | Where-Object { $null -ne $_ }).Count -gt 0
                } while ($workspaceExists)
                Write-AvmLog -Level Info -Message "Confirmed workspace $resourceName is absent after purge."
            }
            break
        }
        { $PSItem -eq 'Microsoft.Subscription/aliases' -and (
                $ResourceId -like '*dep-sub-blzv-tests*' -or -not [string]::IsNullOrWhiteSpace($SubscriptionCleanupManagementGroupId)
            ) } {
            $targetManagementGroupId = if ([string]::IsNullOrWhiteSpace($SubscriptionCleanupManagementGroupId)) {
                'bicep-lz-vending-automation-decom'
            }
            else {
                $SubscriptionCleanupManagementGroupId
            }
            if ($targetManagementGroupId -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or
                $targetManagementGroupId -in @('.', '..') -or $targetManagementGroupId.EndsWith('.')) {
                throw [AvmConfigurationException]::new('Subscription cleanup requires a valid target management group before mutation.')
            }
            $subscriptionName = $ResourceId.Split('/')[4]
            $subscriptions = @(Get-AzSubscription | Where-Object { $_.Name -eq $subscriptionName })
            if ($subscriptions.Count -ne 1) {
                throw [AvmProcessException]::new("Expected one subscription for alias '$subscriptionName'; found $($subscriptions.Count).")
            }
            $subscription = $subscriptions[0]
            $subscriptionId = $subscription.Id
            $subscriptionState = $subscription.State

            $null = Set-AzContext -SubscriptionId $subscriptionId -Scope Process -ErrorAction Stop

            if (-not (Invoke-AvmBicepCleanupLookup -Command 'Get-AzManagementGroupSubscription' -Parameters @{
                        GroupName      = $targetManagementGroupId
                        SubscriptionId = $subscriptionId
                    })) {
                Write-AvmLog -Level Info -Message "Moving subscription $subscriptionName to management group $targetManagementGroupId."
                if ($PSCmdlet.ShouldProcess("Subscription [$subscriptionName] to Management Group: $targetManagementGroupId", 'Move')) {
                    $null = New-AzManagementGroupSubscription -GroupName $targetManagementGroupId -SubscriptionId $subscriptionId
                }
            }

            if (Invoke-AvmBicepCleanupLookup -Command 'Get-AzResourceGroup' -Parameters @{ Name = 'NetworkWatcherRG' }) {
                if ($PSCmdlet.ShouldProcess('Resource Group [NetworkWatcherRG]', 'Remove')) {
                    $null = Remove-AzResourceGroup -Name 'NetworkWatcherRG' -Force
                }
            }

            if ($subscriptionState -eq 'Enabled') {
                Write-AvmLog -Level Info -Message "Disabling subscription $subscriptionName."
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
                    Write-AvmLog -Level Info -Message "Removing API Management service $resourceName from $resourceGroupName (attempt $retryCount/$retryLimit)."

                    if ($PSCmdlet.ShouldProcess("API Management service [$resourceName]", 'Remove')) {
                        $deleteOutput = Invoke-AvmBicepCleanupCli -ArgumentList @(
                            'apim', 'delete', '--resource-group', $resourceGroupName, '--name', $resourceName, '--yes'
                        ) -IgnoreExitCode

                        if ($deleteOutput.ExitCode -eq 0) {
                            $deleteSucceeded = $true
                            Write-AvmLog -Level Info -Message "Requested deletion of API Management service $resourceName."
                        }
                        else {
                            $deleteOutputString = $deleteOutput.StdErr
                            if ($deleteOutputString -match 'ServiceLocked|transitioning') {
                                Write-AvmLog -Level Info -Message "Waiting $retryInterval seconds for API Management service $resourceName to finish transitioning ($retryCount/$retryLimit)."
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
                        Write-AvmLog -Level Info -Message "Confirmed API Management service $resourceName is soft-deleted."
                    }
                    else {
                        Write-AvmLog -Level Info -Message "Waiting $retryInterval seconds for API Management service $resourceName to be soft-deleted ($retryCount/$retryLimit)."
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
                    Write-AvmLog -Level Info -Message "Purging API Management service $resourceName in $apimLocation..."
                    if ($PSCmdlet.ShouldProcess("API Management service [$resourceName]", 'Purge')) {
                        $null = Invoke-AvmBicepCleanupCli -ArgumentList @(
                            'apim', 'deletedservice', 'purge', '--service-name', $resourceName, '--location', $apimLocation
                        )
                        Write-AvmLog -Level Info -Message "Requested purge of API Management service $resourceName."
                    }
                }
                else {
                    Write-AvmLog -Level Info -Message "Skipped purge of API Management service ${resourceName}: no soft-deleted service found in $apimLocation."
                }
            }
            else {

                Write-AvmLog -Level Info -Message "Checking for a soft-deleted API Management service ${resourceName}: not found in $resourceGroupName."
                $softDeletedServices = @(Get-AvmBicepCleanupRestCollection -Path (
                        "/subscriptions/$subscriptionId/providers/Microsoft.ApiManagement/deletedservices?api-version=2021-08-01"
                    ))
                if ($softDeletedServices) {
                    $matchingDeleted = $softDeletedServices |
                        Where-Object { $_.properties.serviceId -ieq $ResourceId }
                    if ($matchingDeleted) {
                        $apimLocation = $matchingDeleted.location
                        Write-AvmLog -Level Info -Message "Purging API Management service $resourceName in $apimLocation..."
                        if ($PSCmdlet.ShouldProcess("API Management service [$resourceName]", 'Purge')) {
                            $null = Invoke-AvmBicepCleanupCli -ArgumentList @(
                                'apim', 'deletedservice', 'purge', '--service-name', $resourceName, '--location', $apimLocation
                            )
                            Write-AvmLog -Level Info -Message "Requested purge of API Management service $resourceName."
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
                        Write-AvmLog -Level Info -Message "Waiting 30 seconds for ExpressRoute gateway $resourceName to be deleted ($retryCount/$maxRetries)."
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
