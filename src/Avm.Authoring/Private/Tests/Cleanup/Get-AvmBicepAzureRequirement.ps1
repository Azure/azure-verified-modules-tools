function Get-AvmBicepAzureRequirement {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $pins = (Read-AvmPins).powerShellModules
    $requirements = @(
        @{
            Name     = 'Az.Accounts'
            Commands = @{
                'Get-AzContext'       = @()
                'Set-AzContext'       = @('Context', 'Subscription', 'Tenant', 'Scope')
                'Get-AzSubscription'  = @()
                'Invoke-AzRestMethod' = @('Method', 'Path', 'Uri', 'Payload')
            }
        }
        @{
            Name     = 'Az.Resources'
            Commands = @{
                'Get-AzResource'                       = @('ResourceId', 'ResourceGroupName', 'ExpandProperties')
                'Remove-AzResource'                    = @('ResourceId', 'Force')
                'Get-AzResourceGroup'                  = @('Name')
                'New-AzResourceGroup'                  = @('Name', 'Location', 'Tag')
                'Test-AzResourceGroupDeployment'       = @('ResourceGroupName', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'Mode')
                'Test-AzSubscriptionDeployment'        = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'Test-AzManagementGroupDeployment'     = @('Name', 'Location', 'ManagementGroupId', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'Test-AzTenantDeployment'              = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'New-AzResourceGroupDeployment'        = @('Name', 'ResourceGroupName', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'Mode', 'Force', 'AsJob', 'Confirm', 'WhatIf')
                'New-AzSubscriptionDeployment'         = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'AsJob', 'Confirm', 'WhatIf')
                'New-AzManagementGroupDeployment'      = @('Name', 'Location', 'ManagementGroupId', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'AsJob', 'Confirm', 'WhatIf')
                'New-AzTenantDeployment'               = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'AsJob', 'Confirm', 'WhatIf')
                'Remove-AzResourceGroup'               = @('Name', 'Force')
                'Get-AzResourceLock'                   = @('Scope', 'LockName')
                'Remove-AzResourceLock'                = @('LockId', 'Force')
                'Get-AzRoleEligibilityScheduleRequest' = @('Scope', 'Name')
                'New-AzRoleEligibilityScheduleRequest' = @('Name', 'Scope', 'PrincipalId', 'RequestType', 'RoleDefinitionId')
                'Get-AzRoleAssignmentScheduleRequest'  = @('Scope', 'Name')
                'New-AzRoleAssignmentScheduleRequest'  = @('Name', 'Scope', 'PrincipalId', 'RequestType', 'RoleDefinitionId')
                'Get-AzManagementGroupSubscription'    = @('GroupName', 'SubscriptionId')
                'New-AzManagementGroupSubscription'    = @('GroupName', 'SubscriptionId')
                'Remove-AzManagementGroup'             = @('GroupName')
            } + @{
                'Get-AzResourceGroupDeploymentWhatIfResult'   = @('Name', 'ResourceGroupName', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'Mode', 'ResultFormat')
                'Get-AzSubscriptionDeploymentWhatIfResult'    = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'ResultFormat')
                'Get-AzManagementGroupDeploymentWhatIfResult' = @('Name', 'Location', 'ManagementGroupId', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'ResultFormat')
                'Get-AzTenantDeploymentWhatIfResult'          = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'ResultFormat')
            }
        }
        @{
            Name     = 'Az.Compute'
            Commands = @{ 'Get-AzDiskEncryptionSet' = @('Name', 'ResourceGroupName') }
        }
        @{
            Name     = 'Az.KeyVault'
            Commands = @{
                'Remove-AzKeyVaultAccessPolicy' = @('VaultName', 'ObjectId')
                'Get-AzKeyVault'                = @('InRemovedState')
                'Get-AzKeyVaultSecret'          = @('VaultName', 'Name')
                'Remove-AzKeyVault'             = @('ResourceId', 'InRemovedState', 'Force', 'Location')
            }
        }
        @{
            Name     = 'Az.RecoveryServices'
            Commands = @{
                'Get-AzRecoveryServicesVaultProperty'        = @('VaultId')
                'Set-AzRecoveryServicesVaultProperty'        = @('VaultId', 'SoftDeleteFeatureState')
                'Get-AzRecoveryServicesBackupItem'           = @('BackupManagementType', 'WorkloadType', 'VaultId', 'Name')
                'Undo-AzRecoveryServicesBackupItemDeletion'  = @('Item', 'VaultId', 'Force')
                'Disable-AzRecoveryServicesBackupProtection' = @('Item', 'VaultId', 'RemoveRecoveryPoints', 'Force')
            }
        }
        @{
            Name     = 'Az.Monitor'
            Commands = @{ 'Remove-AzDiagnosticSetting' = @('ResourceId', 'Name') }
        }
        @{
            Name     = 'Az.CognitiveServices'
            Commands = @{
                'Get-AzCognitiveServicesAccount'    = @('InRemovedState')
                'Remove-AzCognitiveServicesAccount' = @('InRemovedState', 'Force', 'Location', 'ResourceGroupName', 'Name')
            }
        }
        @{
            Name     = 'Az.OperationalInsights'
            Commands = @{ 'Remove-AzOperationalInsightsWorkspace' = @('ResourceGroupName', 'Name', 'Force', 'ForceDelete') }
        }
        @{
            Name     = 'Az.MachineLearningServices'
            Commands = @{ 'Get-AzMLWorkspace' = @('Name', 'ResourceGroupName', 'SubscriptionId') }
        }
        @{
            Name     = 'Az.Network'
            Commands = @{
                'Get-AzExpressRouteGateway'    = @('Name', 'ResourceGroupName')
                'Remove-AzExpressRouteGateway' = @('Name', 'ResourceGroupName', 'Force')
            }
        }
        @{
            Name     = 'Az.DataProtection'
            Commands = @{
                'Get-AzDataProtectionBackupVault'               = @('ResourceGroupName', 'VaultName')
                'Update-AzDataProtectionBackupVault'            = @('ResourceGroupName', 'VaultName', 'ImmutabilityState', 'SoftDeleteState')
                'Get-AzDataProtectionSoftDeletedBackupInstance' = @('ResourceGroupName', 'VaultName')
                'Undo-AzDataProtectionBackupInstanceDeletion'   = @('ResourceGroupName', 'VaultName', 'BackupInstanceName')
                'Get-AzDataProtectionBackupInstance'            = @('ResourceGroupName', 'VaultName')
                'Remove-AzDataProtectionBackupInstance'         = @('ResourceGroupName', 'VaultName', 'Name')
                'Get-AzDataProtectionBackupPolicy'              = @('ResourceGroupName', 'VaultName')
                'Remove-AzDataProtectionBackupPolicy'           = @('ResourceGroupName', 'VaultName', 'Name')
                'Remove-AzDataProtectionBackupVault'            = @('ResourceGroupName', 'VaultName')
            }
        }
        @{
            Name     = 'Az.Subscription'
            Commands = @{ 'Disable-AzSubscription' = @('SubscriptionId') }
        }
    )
    foreach ($requirement in $requirements) {
        if (-not $pins.ContainsKey($requirement.Name)) {
            throw [AvmConfigurationException]::new("No PowerShell module pin for '$($requirement.Name)'.")
        }
        $requirement.MinimumVersion = $pins[$requirement.Name].version
        [pscustomobject]$requirement
    }
}
