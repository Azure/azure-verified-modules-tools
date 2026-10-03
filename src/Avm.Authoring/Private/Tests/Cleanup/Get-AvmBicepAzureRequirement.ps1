function Get-AvmBicepAzureRequirement {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $requirements = @(
        @{
            Name = 'Az.Accounts'; MinimumVersion = '5.3.4'
            Commands = @{
                'Get-AzContext'       = @()
                'Set-AzContext'       = @('Context', 'Subscription', 'Tenant', 'Scope')
                'Get-AzSubscription'  = @()
                'Invoke-AzRestMethod' = @('Method', 'Path', 'Uri', 'Payload')
            }
        }
        @{
            Name = 'Az.Resources'; MinimumVersion = '9.0.3'
            Commands = @{
                'Get-AzResource'                       = @('ResourceId', 'ResourceGroupName', 'ExpandProperties')
                'Remove-AzResource'                    = @('ResourceId', 'Force')
                'Get-AzResourceGroup'                  = @('Name')
                'New-AzResourceGroup'                  = @('Name', 'Location', 'Tag')
                'Get-AzResourceProvider'               = @('ProviderNamespace')
                'Get-AzLocation'                       = @()
                'Test-AzResourceGroupDeployment'       = @('ResourceGroupName', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'Mode')
                'Test-AzSubscriptionDeployment'        = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'Test-AzManagementGroupDeployment'     = @('Name', 'Location', 'ManagementGroupId', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'Test-AzTenantDeployment'              = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'New-AzResourceGroupDeployment'        = @('Name', 'ResourceGroupName', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt', 'Mode', 'Force')
                'New-AzSubscriptionDeployment'         = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'New-AzManagementGroupDeployment'      = @('Name', 'Location', 'ManagementGroupId', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'New-AzTenantDeployment'               = @('Name', 'Location', 'TemplateFile', 'TemplateParameterObject', 'SkipTemplateParameterPrompt')
                'Remove-AzResourceGroup'               = @('Name', 'Force')
                'Get-AzResourceLock'                   = @('Scope', 'LockName')
                'Remove-AzResourceLock'                = @('LockId', 'Force')
                'Get-AzRoleAssignment'                 = @('Scope')
                'Remove-AzRoleAssignment'              = @('InputObject')
                'Get-AzRoleEligibilityScheduleRequest' = @('Scope', 'Name')
                'New-AzRoleEligibilityScheduleRequest' = @('Name', 'Scope', 'PrincipalId', 'RequestType', 'RoleDefinitionId')
                'Get-AzRoleAssignmentScheduleRequest'  = @('Scope', 'Name')
                'New-AzRoleAssignmentScheduleRequest'  = @('Name', 'Scope', 'PrincipalId', 'RequestType', 'RoleDefinitionId')
                'Get-AzManagementGroupSubscription'    = @('GroupName', 'SubscriptionId')
                'New-AzManagementGroupSubscription'    = @('GroupName', 'SubscriptionId')
            }
        }
        @{
            Name = 'Az.Compute'; MinimumVersion = '11.4.0'
            Commands = @{ 'Get-AzDiskEncryptionSet' = @('Name', 'ResourceGroupName') }
        }
        @{
            Name = 'Az.KeyVault'; MinimumVersion = '6.4.3'
            Commands = @{
                'Remove-AzKeyVaultAccessPolicy' = @('VaultName', 'ObjectId')
                'Get-AzKeyVault'                = @('InRemovedState')
                'Get-AzKeyVaultSecret'          = @('VaultName', 'Name')
                'Remove-AzKeyVault'             = @('ResourceId', 'InRemovedState', 'Force', 'Location')
            }
        }
        @{
            Name = 'Az.RecoveryServices'; MinimumVersion = '7.11.2'
            Commands = @{
                'Get-AzRecoveryServicesVaultProperty'        = @('VaultId')
                'Set-AzRecoveryServicesVaultProperty'        = @('VaultId', 'SoftDeleteFeatureState')
                'Get-AzRecoveryServicesBackupItem'           = @('BackupManagementType', 'WorkloadType', 'VaultId', 'Name')
                'Undo-AzRecoveryServicesBackupItemDeletion'  = @('Item', 'VaultId', 'Force')
                'Disable-AzRecoveryServicesBackupProtection' = @('Item', 'VaultId', 'RemoveRecoveryPoints', 'Force')
            }
        }
        @{
            Name = 'Az.Monitor'; MinimumVersion = '7.0.0'
            Commands = @{ 'Remove-AzDiagnosticSetting' = @('ResourceId', 'Name') }
        }
        @{
            Name = 'Az.CognitiveServices'; MinimumVersion = '1.16.0'
            Commands = @{
                'Get-AzCognitiveServicesAccount'    = @('InRemovedState')
                'Remove-AzCognitiveServicesAccount' = @('InRemovedState', 'Force', 'Location', 'ResourceGroupName', 'Name')
            }
        }
        @{
            Name = 'Az.OperationalInsights'; MinimumVersion = '3.3.0'
            Commands = @{ 'Remove-AzOperationalInsightsWorkspace' = @('ResourceGroupName', 'Name', 'Force', 'ForceDelete') }
        }
        @{
            Name = 'Az.MachineLearningServices'; MinimumVersion = '1.3.0'
            Commands = @{ 'Get-AzMLWorkspace' = @('Name', 'ResourceGroupName', 'SubscriptionId') }
        }
        @{
            Name = 'Az.Network'; MinimumVersion = '7.26.0'
            Commands = @{
                'Get-AzExpressRouteGateway'    = @('Name', 'ResourceGroupName')
                'Remove-AzExpressRouteGateway' = @('Name', 'ResourceGroupName', 'Force')
            }
        }
        @{
            Name = 'Az.DataProtection'; MinimumVersion = '2.9.1'
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
            Name = 'Az.Subscription'; MinimumVersion = '0.12.0'
            Commands = @{ 'Disable-AzSubscription' = @('SubscriptionId') }
        }
    )
    foreach ($requirement in $requirements) {
        [pscustomobject]$requirement
    }
}
