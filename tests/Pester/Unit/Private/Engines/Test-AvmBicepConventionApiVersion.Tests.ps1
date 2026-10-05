#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).ProviderPath
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:repoRoot 'tests' 'Pester' 'Import-AvmBicepConventionRule.ps1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmBicepConventionApiVersion' -Tag 'Unit' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule = [pscustomobject]@{
                Path = (Join-Path $TestDrive 'main.bicep')
                Template = @{
                    resources = @(
                        @{
                            type = 'Microsoft.Storage/storageAccounts'
                            apiVersion = '2024-05-01'
                        }
                    )
                }
            }
            $script:apiSpecs = @{
                'Microsoft.Storage' = @{
                    storageAccounts = @(
                        '2020-01-01', '2021-01-01', '2022-01-01', '2023-01-01',
                        '2023-05-01', '2023-12-01', '2024-01-01-preview', '2024-05-01'
                    )
                }
                'Microsoft.Insights' = @{
                    diagnosticSettings = @('2021-05-01-preview')
                }
                'Microsoft.Authorization' = @{
                    locks = @('2020-05-01')
                    roleAssignments = @('2022-04-01')
                }
                'Microsoft.Network' = @{
                    privateEndpoints = @('2024-01-01')
                }
                'Microsoft.ContainerService' = @{
                    managedClusters = @('2024-09-01')
                }
            }
        }
    }

    It 'accepts current stable and preview API versions and excludes deployment/existing resources' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] = @(
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-05-01' },
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-01-01-preview' },
                @{ type = 'Microsoft.Resources/deployments'; apiVersion = '2022-09-01' },
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2021-01-01'; existing = $true }
            )
            @(Test-AvmBicepConventionApiVersion -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs).Count |
                Should -Be 0
        }
    }

    It 'warns for outdated and last-approved stable versions without failing the whole check' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] = @(
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2021-01-01' },
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2022-01-01' }
            )
            $issues = @(Test-AvmBicepConventionApiVersion -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues.Count | Should -Be 2
            $issues.Code | Should -Contain 'avm.bicep.api-version-outdated'
            $issues.Code | Should -Contain 'avm.bicep.api-version-near-expiry'
            @($issues | Where-Object Severity -EQ 'warning').Count | Should -Be 2
        }
    }

    It 'checks symbolic nested resources and remaps extension providers' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] = [ordered]@{
                nestedDeployment = @{
                    type = 'Microsoft.Resources/deployments'
                    apiVersion = '2022-09-01'
                    properties = @{
                        template = @{
                            resources = [ordered]@{
                                cluster = @{
                                    type = 'Microsoft.ContainerService/managedClusters'
                                    apiVersion = '2024-09-01'
                                }
                            }
                        }
                    }
                }
                diagnostics = @{
                    type = 'Microsoft.Storage/storageAccounts/providers/Microsoft.Insights/diagnosticSettings'
                    apiVersion = '2021-05-01-preview'
                }
                lock = @{
                    type = 'Microsoft.Storage/storageAccounts/providers/Microsoft.Authorization/locks'
                    apiVersion = '2020-05-01'
                }
                role = @{
                    type = 'Microsoft.Storage/storageAccounts/providers/Microsoft.Authorization/roleAssignments'
                    apiVersion = '2022-04-01'
                }
                endpoint = @{
                    type = 'Microsoft.Storage/storageAccounts/providers/Microsoft.Network/privateEndpoints'
                    apiVersion = '2024-01-01'
                }
            }
            @(Test-AvmBicepConventionApiVersion -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs).Count |
                Should -Be 0
        }
    }

    It 'warns when no type/provider entry can establish a recency window' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] = @(
                @{ type = 'Microsoft.Other/widgets'; apiVersion = '2023-05-01' },
                @{ type = 'Microsoft.Storage/unknownResources'; apiVersion = '2023-05-01' }
            )
            $issues = @(Test-AvmBicepConventionApiVersion -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues.Code | Should -Contain 'avm.bicep.api-provider-unknown'
            $issues.Code | Should -Contain 'avm.bicep.api-type-unknown'
            @($issues | Where-Object Severity -EQ 'warning').Count | Should -Be 2
        }
    }

    It 'fails instead of silently passing when the API source is unavailable' {
        InModuleScope 'Avm.Authoring' {
            $issues = @(Test-AvmBicepConventionApiVersion -Root $TestDrive -Modules @($script:apiModule) `
                    -ApiSpecsUnavailableReason 'source unavailable')
            $issues.Count | Should -Be 1
            $issues[0].Code | Should -BeExactly 'avm.bicep.api-specs-unavailable'
            $issues[0].Severity | Should -BeExactly 'error'
        }
    }

    It 'fails for malformed known-provider API lists and resource shapes' {
        InModuleScope 'Avm.Authoring' {
            $script:apiSpecs = @{ 'Microsoft.Storage' = @{ storageAccounts = 'not an array' } }

            $script:apiModule.Template['resources'] = @(
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2023-05-01' },
                @{ type = 'BadType'; apiVersion = '2023-05-01' },
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = 'invalid' },
                'not a resource object'
            )
            $issues = @(Test-AvmBicepConventionApiVersion -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues.Code | Should -Contain 'avm.bicep.api-specs-invalid'
            $issues.Code | Should -Contain 'avm.bicep.api-resource-invalid'
            $issues.Code | Should -Contain 'avm.bicep.api-version-invalid'
        }
    }
}
