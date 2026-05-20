#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmArmResource' {
    It 'returns an empty array for an ARM template with no resources property' {
        $arm = [pscustomobject]@{ outputs = [pscustomobject]@{} }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        $result.Count | Should -Be 0
    }

    It 'returns an empty array when resources is an empty array' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        $result.Count | Should -Be 0
    }

    It 'extracts Type and ApiVersion from a single top-level resource' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview'; name = 'kv' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        $result.Count          | Should -Be 1
        $result[0].Type        | Should -Be 'Microsoft.KeyVault/vaults'
        $result[0].ApiVersion  | Should -Be '2024-04-01-preview'
    }

    It 'preserves walk order and keeps duplicate (Type, ApiVersion) pairs (dedupe is caller-owned)' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-01-01' },
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' },
                [pscustomobject]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-01-01' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        $result.Count          | Should -Be 3
        $result[0].Type        | Should -Be 'Microsoft.Storage/storageAccounts'
        $result[1].Type        | Should -Be 'Microsoft.KeyVault/vaults'
        $result[2].Type        | Should -Be 'Microsoft.Storage/storageAccounts'
    }

    It 'descends into inline child resources' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{
                    type       = 'Microsoft.KeyVault/vaults'
                    apiVersion = '2024-04-01-preview'
                    resources  = @(
                        [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults/accessPolicies'; apiVersion = '2024-04-01-preview' }
                    )
                }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        $result.Count          | Should -Be 2
        $result.Type           | Should -Contain 'Microsoft.KeyVault/vaults'
        $result.Type           | Should -Contain 'Microsoft.KeyVault/vaults/accessPolicies'
    }

    It 'descends into nested-deployment template resources' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{
                    type       = 'Microsoft.Resources/deployments'
                    apiVersion = '2022-09-01'
                    properties = [pscustomobject]@{
                        template = [pscustomobject]@{
                            resources = @(
                                [pscustomobject]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-01-01' },
                                [pscustomobject]@{ type = 'Microsoft.Network/virtualNetworks'; apiVersion = '2023-11-01' }
                            )
                        }
                    }
                }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        # Deployment wrapper itself + both nested resources.
        $result.Count | Should -Be 3
        $result.Type  | Should -Contain 'Microsoft.Resources/deployments'
        $result.Type  | Should -Contain 'Microsoft.Storage/storageAccounts'
        $result.Type  | Should -Contain 'Microsoft.Network/virtualNetworks'
    }

    It 'skips resources missing either type or apiVersion without throwing' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.Storage/storageAccounts' }, # no apiVersion
                [pscustomobject]@{ apiVersion = '2024-01-01' }, # no type
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmResource -Arm $A
        }
        $result.Count          | Should -Be 1
        $result[0].Type        | Should -Be 'Microsoft.KeyVault/vaults'
    }
}
