#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsRoleName' {
    It 'retains qualified identifiers for root and nested deployment role maps' {
        $template = @{
            variables = @{ builtInRoleNames = [ordered]@{
                    'Owner'       = 'owner-id'
                    'Contributor' = 'contributor-id'
                }
            }
            resources = @{
                keyVault_keys = @{
                    type       = 'Microsoft.Resources/deployments'
                    apiVersion = '2025-04-01'
                    properties = @{
                        template = @{
                            variables = @{ builtInRoleNames = [ordered]@{
                                    'Key Vault Administrator' = 'admin-id'
                                    'Contributor'             = 'contributor-id'
                                }
                            }
                            resources = @{}
                        }
                    }
                }
                keyVault_secrets = @{
                    type       = 'Microsoft.Resources/deployments'
                    apiVersion = '2025-04-01'
                    properties = @{
                        template = @{
                            variables = @{ builtInRoleNames = [ordered]@{
                                    'Key Vault Secrets User' = 'user-id'
                                }
                            }
                        }
                    }
                }
            }
        }
        $roles = InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            Get-AvmBicepDocsRoleName -Template $T -SourcePath 'synthetic/main.json'
        }
        @($roles | Where-Object Identifier -EQ '')[0].Names |
            Should -Be @('Owner', 'Contributor')
        @($roles | Where-Object Identifier -EQ 'keyVault_keys')[0].Names |
            Should -Be @('Key Vault Administrator', 'Contributor')
        @($roles | Where-Object Identifier -EQ 'keyVault_secrets')[0].Names |
            Should -Be @('Key Vault Secrets User')
    }

    It 'does not conflate distinct nested deployment maps with a shared suffix' {
        $template = @{
            resources = @{
                workspace_privateEndpoints = @{
                    type       = 'Microsoft.Resources/deployments'
                    properties = @{
                        template = @{
                            variables = @{
                                builtInRoleNames = @{ Contributor = 'contributor-id' }
                            }
                        }
                    }
                }
                registry_privateEndpoints = @{
                    type       = 'Microsoft.Resources/deployments'
                    properties = @{
                        template = @{
                            variables = @{
                                builtInRoleNames = @{ Owner = 'owner-id' }
                            }
                        }
                    }
                }
            }
        }
        $roles = InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            Get-AvmBicepDocsRoleName -Template $T -SourcePath 'synthetic/main.json'
        }
        @($roles.Identifier | Sort-Object) | Should -Be @(
            'registry_privateEndpoints', 'workspace_privateEndpoints'
        )
        @($roles | Where-Object Identifier -EQ 'registry_privateEndpoints')[0].Names |
            Should -Be @('Owner')
        @($roles | Where-Object Identifier -EQ 'workspace_privateEndpoints')[0].Names |
            Should -Be @('Contributor')
    }

    It 'rejects malformed compiled role maps instead of omitting allowed roles' {
        {
            InModuleScope 'Avm.Authoring' {
                Get-AvmBicepDocsRoleName -Template @{
                    variables = @{ builtInRoleNames = @('Contributor') }
                } -SourcePath 'synthetic/main.json'
            }
        } | Should -Throw '*builtInRoleNames must be a JSON object*'
    }
}
