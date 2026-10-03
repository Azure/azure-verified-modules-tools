#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:New-TestCleanupState {
            @{
                schemaVersion = 1
                runId = '00000000000000000000000000000010'
                tenantId = '00000000-0000-0000-0000-000000000002'
                subscriptionId = '00000000-0000-0000-0000-000000000001'
                environment = 'AzureCloud'
                status = 'Pending'
                deployments = @()
                ownedResourceGroups = @()
                resources = @()
            }
        }
        function script:New-TestCleanupResource {
            param(
                [string] $Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account'
            )
            @{
                id = $Id
                type = (ConvertTo-AvmBicepCleanupResource -ResourceIds @($Id)).type
                removed = $false
                postProcessed = $false
                metadataCaptured = $false
                managedResourceGroupIds = @()
                originalSoftDeleteFeatureState = ''
            }
        }
        function script:Get-AzResourceGroup {
            [CmdletBinding()]
            param($Name)
            throw 'Unexpected Azure group lookup.'
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep cleanup state validation' {
    It 'rejects an invalid root field: <Label>' -ForEach @(
        @{ Label = 'Boolean version'; Field = 'schemaVersion'; Value = $true }
        @{ Label = 'unknown version'; Field = 'schemaVersion'; Value = 2 }
        @{ Label = 'run ID'; Field = 'runId'; Value = '../run' }
        @{ Label = 'empty subscription'; Field = 'subscriptionId'; Value = '00000000-0000-0000-0000-000000000000' }
        @{ Label = 'malformed tenant'; Field = 'tenantId'; Value = 'not-a-guid' }
        @{ Label = 'missing cloud'; Field = 'environment'; Value = '' }
        @{ Label = 'status'; Field = 'status'; Value = 'Success' }
        @{ Label = 'scalar deployments'; Field = 'deployments'; Value = 'deployment' }
        @{ Label = 'scalar groups'; Field = 'ownedResourceGroups'; Value = @{} }
        @{ Label = 'missing resources'; Field = 'resources'; Value = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            $state = New-TestCleanupState
            $state[$Field] = $Value
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw
        }
    }

    It 'derives resource types from IDs and discards unapproved nested fields' {
        InModuleScope Avm.Authoring {
            $state = New-TestCleanupState
            $entry = New-TestCleanupResource
            $entry.type = 'Microsoft.Resources/resourceGroups'
            $entry.response = @{ password = 'not-for-state' }
            $state.resources = @($entry)
            $actual = ConvertTo-AvmBicepCleanupState -State $state
            $actual.resources[0].type | Should -BeExactly 'Microsoft.Storage/storageAccounts'
            $actual.resources[0].Contains('response') | Should -BeFalse
            $actual.resources[0].metadataCaptured | Should -BeFalse
        }
    }

    It 'rejects duplicate deployment IDs regardless of casing' {
        InModuleScope Avm.Authoring {
            $state = New-TestCleanupState
            $id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/attempt'
            $state.deployments = @(
                @{ id = $id; status = 'Attempted'; preflightRejected = $false }
                @{ id = $id.ToUpperInvariant(); status = 'Failed'; preflightRejected = $false }
            )
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*distinct deployment*'
        }
    }

    It 'rejects non-deployment targets and non-Boolean rejection flags' {
        InModuleScope Avm.Authoring {
            $state = New-TestCleanupState
            $state.deployments = @(@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
                    status = 'Succeeded'; preflightRejected = $false
                })
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*deployment resources*'
            $state.deployments[0].preflightRejected = 'false'
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*deployment record*'
        }
    }

    It 'rejects duplicate or invalid owned group records' {
        InModuleScope Avm.Authoring {
            $state = New-TestCleanupState
            $entry = @{
                id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test'
                runId = $state.runId
            }
            $state.ownedResourceGroups = @($entry, $entry)
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*distinct resource groups*'
            $state.ownedResourceGroups = @($entry)
            $entry.id += '/providers/Microsoft.Storage/storageAccounts/account'
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*resource groups*'
            $entry.runId = 'unverified'
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*owned resource-group*'
        }
    }

    It 'rejects inconsistent resource completion: <Label>' -ForEach @(
        @{ Label = 'post without removal'; Removed = $false; PostProcessed = $true; MetadataCaptured = $true }
        @{ Label = 'removal without metadata'; Removed = $true; PostProcessed = $false; MetadataCaptured = $false }
        @{ Label = 'string Boolean'; Removed = 'false'; PostProcessed = $false; MetadataCaptured = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{
            Removed = $Removed; PostProcessed = $PostProcessed; MetadataCaptured = $MetadataCaptured
        } {
            param($Removed, $PostProcessed, $MetadataCaptured)
            $state = New-TestCleanupState
            $resource = New-TestCleanupResource
            $resource.removed = $Removed
            $resource.postProcessed = $PostProcessed
            $resource.metadataCaptured = $MetadataCaptured
            $state.resources = @($resource)
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*resource*'
        }
    }

    It 'rejects a complete outcome with unfinished resources' {
        InModuleScope Avm.Authoring {
            $state = New-TestCleanupState
            $state.resources = @(New-TestCleanupResource)
            $state.status = 'Complete'
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*unfinished resources*'
            $state.resources[0].metadataCaptured = $true
            $state.resources[0].removed = $true
            $state.resources[0].postProcessed = $true
            (ConvertTo-AvmBicepCleanupState -State $state).status | Should -BeExactly 'Complete'
        }
    }

    It 'rejects foreign managed groups and unrelated recovery settings' {
        InModuleScope Avm.Authoring {
            $state = New-TestCleanupState
            $workspace = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Databricks/workspaces/workspace'
            $workspace.managedResourceGroupIds = @('/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/managed')
            $state.resources = @($workspace)
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*Databricks managed group*'
            $workspace.managedResourceGroupIds = @()
            $workspace.originalSoftDeleteFeatureState = 'Enabled'
            { ConvertTo-AvmBicepCleanupState -State $state } | Should -Throw -ExpectedMessage '*recovery-vault setting*'
        }
    }
}

Describe 'Bicep cleanup metadata capture' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepCleanupLookup { throw 'Unexpected Azure lookup.' }
            Mock Get-AzResourceGroup { throw 'Unexpected Azure group listing.' }
        }
    }

    It 'retains the actual Databricks managed group before workspace removal' {
        InModuleScope Avm.Authoring {
            $resource = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Databricks/workspaces/workspace'
            $managed = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/custom-managed'
            Mock Invoke-AvmBicepCleanupLookup {
                @{ Properties = @{ managedResourceGroupId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/custom-managed' } }
            }
            Initialize-AvmBicepCleanupResource -Resource $resource
            $resource.metadataCaptured | Should -BeTrue
            $resource.managedResourceGroupIds | Should -Be @($managed)
            Should -Invoke Invoke-AvmBicepCleanupLookup -Exactly 1 -ParameterFilter {
                $Command -eq 'Get-AzResource' -and $Parameters.ExpandProperties -eq $true -and
                $Parameters.ResourceId -like '*/Microsoft.Databricks/workspaces/workspace'
            }
            Should -Invoke Get-AzResourceGroup -Exactly 0
        }
    }

    It 'recovers managed groups only from exact workspace ownership after removal' {
        InModuleScope Avm.Authoring {
            $resource = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Databricks/workspaces/workspace'
            $script:workspaceId = $resource.id
            Mock Invoke-AvmBicepCleanupLookup { $null }
            Mock Get-AzResourceGroup {
                @{ ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/custom-managed'; ManagedBy = $script:workspaceId }
                @{ ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-managed'; ManagedBy = "$script:workspaceId-other" }
            }
            Initialize-AvmBicepCleanupResource -Resource $resource
            $resource.managedResourceGroupIds.Count | Should -Be 1
            $resource.managedResourceGroupIds[0] | Should -BeLike '*/custom-managed'
            $resource.metadataCaptured | Should -BeTrue
        }
    }

    It 'does not acknowledge a missing or foreign Databricks managed group: <Label>' -ForEach @(
        @{ Label = 'missing ID'; Id = $null }
        @{ Label = 'another subscription'; Id = '/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/managed' }
        @{ Label = 'not a group'; Id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/account' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Id = $Id } {
            param($Id)
            $resource = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Databricks/workspaces/workspace'
            $script:managedId = $Id
            Mock Invoke-AvmBicepCleanupLookup { @{ Properties = @{ managedResourceGroupId = $script:managedId } } }
            { Initialize-AvmBicepCleanupResource -Resource $resource } | Should -Throw -ExpectedMessage '*managed resource-group ID*'
            $resource.metadataCaptured | Should -BeFalse
        }
    }

    It 'retains the original vault setting with case-insensitive child IDs' {
        InModuleScope Avm.Authoring {
            $resource = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.RecoveryServices/vaults/vault/BACKUPFABRICS/Azure/protectionContainers/container/protectedItems/item'
            Mock Invoke-AvmBicepCleanupLookup { @{ SoftDeleteFeatureState = 'Enabled' } }
            Initialize-AvmBicepCleanupResource -Resource $resource
            $resource.originalSoftDeleteFeatureState | Should -BeExactly 'Enabled'
            $resource.metadataCaptured | Should -BeTrue
            Should -Invoke Invoke-AvmBicepCleanupLookup -Exactly 1 -ParameterFilter {
                $Command -eq 'Get-AzRecoveryServicesVaultProperty' -and
                $Parameters.VaultId -ceq '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.RecoveryServices/vaults/vault'
            }
            Initialize-AvmBicepCleanupResource -Resource $resource
            Should -Invoke Invoke-AvmBicepCleanupLookup -Exactly 1
        }
    }

    It 'leaves metadata pending if the vault setting is unavailable or unrecognized' {
        InModuleScope Avm.Authoring {
            $resource = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.RecoveryServices/vaults/vault/backupFabrics/Azure/protectionContainers/container/protectedItems/item'
            Mock Invoke-AvmBicepCleanupLookup { @{ SoftDeleteFeatureState = 'unrecognized' } }
            { Initialize-AvmBicepCleanupResource -Resource $resource } | Should -Throw -ExpectedMessage '*soft-delete setting*'
            $resource.metadataCaptured | Should -BeFalse
            Mock Invoke-AvmBicepCleanupLookup { throw 'Access denied' }
            { Initialize-AvmBicepCleanupResource -Resource $resource } | Should -Throw -ExpectedMessage '*Access denied*'
            $resource.metadataCaptured | Should -BeFalse
        }
    }

    It 'acknowledges an already absent vault without fabricating its setting' {
        InModuleScope Avm.Authoring {
            $resource = New-TestCleanupResource -Id '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.RecoveryServices/vaults/vault/backupFabrics/Azure/protectionContainers/container/protectedItems/item'
            Mock Invoke-AvmBicepCleanupLookup { $null }
            Initialize-AvmBicepCleanupResource -Resource $resource
            $resource.metadataCaptured | Should -BeTrue
            $resource.originalSoftDeleteFeatureState | Should -BeExactly ''
        }
    }
}

Describe 'Bicep cleanup dependency preflight' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepAzureRequirement {
                [pscustomobject]@{
                    Name = 'Az.Accounts'; MinimumVersion = '5.3.4'
                    Commands = @{ 'Get-AzContext' = @() }
                }
            }
            Mock Import-Module { throw 'Unexpected module import.' }
            Mock Get-Command { throw 'Unexpected command lookup.' }
        }
    }

    It 'rejects an older loaded version before attempting imports' {
        InModuleScope Avm.Authoring {
            Mock Get-Module {
                param($ListAvailable)
                if ($ListAvailable) {
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.3.4'; Path = 'accounts.psd1' }
                }
                else {
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'4.0.0'; Path = 'old-accounts.psd1' }
                }
            }
            { Assert-AvmBicepAzureDependency } | Should -Throw -ExpectedMessage '*fresh PowerShell session*'
            Should -Invoke Import-Module -Exactly 0
            Should -Invoke Get-Command -Exactly 0
        }
    }

    It 'does not autoload a command from a wrong module or old version: <Label>' -ForEach @(
        @{ Label = 'wrong module'; Module = 'Unrelated'; Version = '5.3.4' }
        @{ Label = 'older command'; Module = 'Az.Accounts'; Version = '4.0.0' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Module = $Module; Version = $Version } {
            param($Module, $Version)
            $script:commandModule = $Module
            $script:commandVersion = [version]$Version
            Mock Get-Module {
                param($ListAvailable)
                if ($ListAvailable) {
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.3.4'; Path = 'accounts.psd1' }
                }
            }
            Mock Import-Module {}
            Mock Get-Command {
                [pscustomobject]@{ ModuleName = $script:commandModule; Version = $script:commandVersion; Parameters = @{} }
            }
            { Assert-AvmBicepAzureDependency } | Should -Throw -ExpectedMessage '*not supplied by the required*'
        }
    }

    It 'imports the newest eligible Accounts path into global scope' {
        InModuleScope Avm.Authoring {
            Mock Get-Module {
                param($ListAvailable)
                if ($ListAvailable) {
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'4.0.0'; Path = 'old.psd1' }
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.3.4'; Path = 'floor.psd1' }
                    [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.4.0'; Path = 'newest.psd1' }
                }
            }
            Mock Import-Module {}
            Mock Get-Command {
                [pscustomobject]@{ ModuleName = 'Az.Accounts'; Version = [version]'5.4.0'; Parameters = @{} }
            }
            Assert-AvmBicepAzureDependency
            Should -Invoke Import-Module -Exactly 1 -ParameterFilter { $Name -ceq 'newest.psd1' -and $Global }
        }
    }

    It 'keeps other dependency imports local to the module' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmBicepAzureRequirement {
                [pscustomobject]@{
                    Name = 'Az.Resources'; MinimumVersion = '9.0.3'
                    Commands = @{ 'Get-AzResource' = @() }
                }
            }
            Mock Get-Module {
                param($ListAvailable)
                if ($ListAvailable) {
                    [pscustomobject]@{ Name = 'Az.Resources'; Version = [version]'9.0.3'; Path = 'resources.psd1' }
                }
            }
            Mock Import-Module {}
            Mock Get-Command {
                [pscustomobject]@{ ModuleName = 'Az.Resources'; Version = [version]'9.0.3'; Parameters = @{} }
            }
            Assert-AvmBicepAzureDependency
            Should -Invoke Import-Module -Exactly 1 -ParameterFilter { $Name -ceq 'resources.psd1' -and -not $Global }
        }
    }
}

Describe 'Bicep cleanup native requirements' {
    It 'requires the separately installed subscription module before importing the Az bundle' {
        InModuleScope Avm.Authoring {
            Mock Get-Module {
                param($Name, $ListAvailable)
                if ($ListAvailable -and $Name -ne 'Az.Subscription') {
                    [pscustomobject]@{ Name = $Name; Version = [version]'99.0.0'; Path = "$Name.psd1" }
                }
            }
            Mock Import-Module { throw 'No modules may be imported with an incomplete dependency set.' }
            { Assert-AvmBicepAzureDependency } | Should -Throw -ExpectedMessage '*Az.Subscription*'
            Should -Invoke Get-Module -Exactly 1 -ParameterFilter { $Name -eq 'Az.Subscription' -and $ListAvailable }
            Should -Invoke Import-Module -Exactly 0
        }
    }
}

Describe 'Bicep cleanup workflow exclusions' {
    It 'retains selected-subscription <Suffix> without excluding another subscription' -ForEach @(
        @{ Suffix = 'resourceGroups/NetworkWatcherRG' }
        @{ Suffix = 'providers/Microsoft.Security/autoProvisioningSettings/default' }
        @{ Suffix = 'providers/Microsoft.Security/deviceSecurityGroups/default' }
        @{ Suffix = 'providers/Microsoft.Security/iotSecuritySolutions/default' }
        @{ Suffix = 'providers/Microsoft.Security/pricings/default' }
        @{ Suffix = 'providers/Microsoft.Security/securityContacts/default' }
        @{ Suffix = 'providers/Microsoft.Security/workspaceSettings/default' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Suffix = $Suffix } {
            param($Suffix)
            $subscription = '00000000-0000-0000-0000-000000000001'
            $target = "/subscriptions/$subscription/$Suffix"
            Test-AvmBicepCleanupExclusion -ResourceId $target.ToUpperInvariant() -SubscriptionId $subscription |
                Should -BeTrue
            Test-AvmBicepCleanupExclusion -ResourceId $target -SubscriptionId '00000000-0000-0000-0000-000000000003' |
                Should -BeFalse
        }
    }

    It 'does not match names or provider types that merely start with an exclusion' {
        InModuleScope Avm.Authoring {
            $subscription = '00000000-0000-0000-0000-000000000001'
            Test-AvmBicepCleanupExclusion -SubscriptionId $subscription `
                -ResourceId "/subscriptions/$subscription/resourceGroups/NetworkWatcherRG-module" |
                Should -BeFalse
            Test-AvmBicepCleanupExclusion -SubscriptionId $subscription `
                -ResourceId "/subscriptions/$subscription/providers/Microsoft.Security/pricingsOther/default" |
                Should -BeFalse
        }
    }
}
