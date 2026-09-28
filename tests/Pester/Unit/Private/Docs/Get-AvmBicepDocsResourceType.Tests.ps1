#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsResourceType' {
    It 'finds transitive resources in language v2 object resources and excludes deployments and existing references' {
        $template = @{
            resources = @{
                deployment = @{
                    type       = 'Microsoft.Resources/deployments'
                    apiVersion = '2025-04-01'
                    properties = @{
                        template = @{
                            resources = @{
                                role = @{
                                    type       = 'Microsoft.Authorization/roleAssignments'
                                    apiVersion = '2022-04-01'
                                }
                                lock = @{
                                    type       = 'Microsoft.Authorization/locks'
                                    apiVersion = '2020-05-01'
                                }
                            }
                        }
                    }
                }
                group = @{
                    type       = 'Microsoft.Resources/resourceGroups'
                    apiVersion = '2025-04-01'
                }
                existing = @{
                    type       = 'Microsoft.Storage/storageAccounts'
                    apiVersion = '2023-05-01'
                    existing   = $true
                }
            }
        }
        $resources = @(InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
                param($T)
                Get-AvmBicepDocsResourceType -Template $T
            })
        @($resources.Type) | Should -Be @(
            'Microsoft.Authorization/locks',
            'Microsoft.Authorization/roleAssignments',
            'Microsoft.Resources/resourceGroups'
        )
        $resources[0].ApiVersion | Should -BeExactly '2020-05-01'
    }

    It 'deduplicates identical type/version pairs but retains distinct versions' {
        $template = @{
            resources = @(
                @{ type = 'Microsoft.Example/resources'; apiVersion = '2025-01-01' },
                @{ type = 'Microsoft.Example/resources'; apiVersion = '2025-01-01' },
                @{ type = 'Microsoft.Example/resources'; apiVersion = '2024-01-01' }
            )
        }
        @(InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
                param($T)
                Get-AvmBicepDocsResourceType -Template $T
            }).Count | Should -Be 2
    }

    It 'keeps compiled traversal order for two versions of the same resource type' {
            $template = @{
                resources = [ordered]@{
                    zFirst = @{
                        type       = 'Microsoft.Resources/deployments'
                        properties = @{
                            template = @{
                                resources = @{
                                    nested = @{
                                        type       = 'Microsoft.Example/items'
                                        apiVersion = '2024-10-01'
                                    }
                                }
                            }
                        }
                    }
                    aSecond = @{
                        type       = 'Microsoft.Resources/deployments'
                        properties = @{
                            template = @{
                                resources = @{
                                    nested = @{
                                        type       = 'Microsoft.Example/items'
                                        apiVersion = '2024-05-01'
                                    }
                                }
                            }
                        }
                    }
                }
            }
            $resources = @(InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
                    param($T)
                    Get-AvmBicepDocsResourceType -Template $T
                })
            @($resources.ApiVersion) | Should -Be @('2024-10-01', '2024-05-01')
    }

    It 'enumerates every resource when one is named values' {
            $template = @{
                resources = @{
                    values = @{ type = 'Microsoft.Example/values'; apiVersion = '2025-01-01' }
                    other = @{ type = 'Microsoft.Example/others'; apiVersion = '2025-01-01' }
                }
            }
            $resources = @(InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
                    param($T)
                    Get-AvmBicepDocsResourceType -Template $T
                })
            @($resources.Type) | Should -Be @('Microsoft.Example/others', 'Microsoft.Example/values')
    }
}
