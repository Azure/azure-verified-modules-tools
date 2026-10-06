#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).ProviderPath
    . (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: native Bicep API version requirements' -Tag 'Component' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:runApiSuite = {
                param($Root, $Modules, $ApiSpecs, [string] $ApiSpecsUnavailableReason = '')
                $data = @{
                    Root = $Root; ApiSpecs = $ApiSpecs; ApiSpecsUnavailableReason = $ApiSpecsUnavailableReason
                    ApiVersionInputs = @($Modules | ForEach-Object { Get-AvmBicepApiVersionInput -Module $_ })
                }
                $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'ApiVersion.Tests.ps1'
                $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Root `
                    -Mode Convention -ConventionData $data -EnvVars @{} -InProcess
                $summary.Total | Should -Be $data.NativeApiVersionExpected
                ($summary.Passed + $summary.Failed) | Should -Be $summary.Total
                $summary.Total | Should -BeGreaterThan 0
                @($summary.Issues | Where-Object Code -like 'avm.bicep.pester-*') | Should -HaveCount 0
                $script:lastApiSummary = $summary
                return $summary.Issues
            }
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

    It 'executes sixteen native requirements and deduplicates identical type/API pairs' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] += $script:apiModule.Template['resources'][0]
            @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs) |
                Should -HaveCount 0
            $script:lastApiSummary.Total | Should -Be 16
            $script:lastApiSummary.Passed | Should -Be 16
        }
    }

    It 'preserves case-insensitive provider and resource-type lookup' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'][0]['type'] = 'microsoft.storage/STORAGEACCOUNTS'
            @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs) |
                Should -HaveCount 0
        }
    }

    It 'does not accept differently cased API suffixes as identical catalog versions' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'][0]['apiVersion'] = '2024-01-01-PREVIEW'
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues | Should -HaveCount 1
            $issues[0].Code | Should -BeExactly 'avm.bicep.api-version-outdated'
            $issues[0].Severity | Should -BeExactly 'warning'
        }
    }

    It 'rejects malformed catalog dates: <Case>' -ForEach @(
        @{ Case = 'empty array'; Versions = @() }
        @{ Case = 'invalid calendar date'; Versions = @('2024-02-31') }
        @{ Case = 'non-string'; Versions = @(123) }
        @{ Case = 'trailing newline'; Versions = @("2024-05-01`n") }
        @{ Case = 'duplicate'; Versions = @('2024-05-01', '2024-05-01') }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Versions = $Versions } {
            param($Versions)
            $script:apiSpecs['Microsoft.Storage']['storageAccounts'] = $Versions
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            @($issues | Where-Object Code -eq 'avm.bicep.api-specs-invalid') | Should -Not -BeNullOrEmpty
            @($issues | Where-Object Severity -eq 'warning') | Should -HaveCount 0
        }
    }

    It 'rejects case-ambiguous catalog <Level> entries' -ForEach @(
        @{ Level = 'provider' }
        @{ Level = 'resource-type' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Level = $Level } {
            param($Level)
            $map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            if ($Level -eq 'provider') {
                $map.Add('Microsoft.Storage', $script:apiSpecs['Microsoft.Storage'])
                $map.Add('microsoft.storage', $script:apiSpecs['Microsoft.Storage'])
                $script:apiSpecs = $map
            }
            else {
                $map.Add('storageAccounts', @('2024-05-01'))
                $map.Add('STORAGEACCOUNTS', @('2024-05-01'))
                $script:apiSpecs['Microsoft.Storage'] = $map
            }
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues | Should -HaveCount 1
            $issues[0].Code | Should -BeExactly 'avm.bicep.api-specs-invalid'
            $issues[0].Severity | Should -BeExactly 'error'
        }
    }

    It 'rejects an impossible resource API date rather than reporting an advisory' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'][0]['apiVersion'] = '2024-02-31'
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues | Should -HaveCount 1
            $issues[0].Code | Should -BeExactly 'avm.bicep.api-version-invalid'
            $issues[0].Severity | Should -BeExactly 'error'
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
            @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs).Count |
                Should -Be 0
        }
    }

    It 'warns for outdated and last-approved stable versions without failing the whole check' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] = @(
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2021-01-01' },
                @{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2022-01-01' }
            )
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
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
            @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs).Count |
                Should -Be 0
        }
    }

    It 'warns when no type/provider entry can establish a recency window' {
        InModuleScope 'Avm.Authoring' {
            $script:apiModule.Template['resources'] = @(
                @{ type = 'Microsoft.Other/widgets'; apiVersion = '2023-05-01' },
                @{ type = 'Microsoft.Storage/unknownResources'; apiVersion = '2023-05-01' }
            )
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues.Code | Should -Contain 'avm.bicep.api-provider-unknown'
            $issues.Code | Should -Contain 'avm.bicep.api-type-unknown'
            @($issues | Where-Object Severity -EQ 'warning').Count | Should -Be 2
        }
    }

    It 'fails instead of silently passing when the API source is unavailable' {
        InModuleScope 'Avm.Authoring' {
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) `
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
            $issues = @(& $script:runApiSuite -Root $TestDrive -Modules @($script:apiModule) -ApiSpecs $script:apiSpecs)
            $issues.Code | Should -Contain 'avm.bicep.api-specs-invalid'
            $issues.Code | Should -Contain 'avm.bicep.api-resource-invalid'
            $issues.Code | Should -Contain 'avm.bicep.api-version-invalid'
        }
    }
}
