#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:runId = '0123456789abcdef0123456789abcdef'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep scoped e2e template safety' {
    It 'accepts reviewed definitions and inspectable inline nested deployments' {
        InModuleScope 'Avm.Authoring' {
            $template = @{
                resources = @(
                    @{
                        type = 'Microsoft.Resources/deployments'
                        properties = @{
                            mode = 'Incremental'
                            parameters = @{}
                            expressionEvaluationOptions = @{ scope = 'inner' }
                            template = @{
                                resources = @(@{
                                        type = 'Microsoft.Authorization/policyDefinitions'
                                        name = 'avm-test'
                                    })
                            }
                        }
                    }
                )
            }
            { Assert-AvmBicepScopedTestIsolation -Template $template `
                    -Scope mg -SourcePath 'case.bicep' } | Should -Not -Throw
        }
    }

    It 'refuses <Kind> before Azure access' -ForEach @(
        @{ Kind = 'role assignments'; Type = 'Microsoft.Authorization/roleAssignments'; Message = '*unsupported*' }
        @{ Kind = 'subscription aliases'; Type = 'Microsoft.Subscription/aliases'; Message = '*unsupported*' }
        @{ Kind = 'deployment scripts'; Type = 'Microsoft.Resources/deploymentScripts'; Message = '*unsupported*' }
        @{ Kind = 'dynamic types'; Type = '[parameters(''type'')]'; Message = '*cannot be verified*' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            ResourceType = $Type; ErrorMessage = $Message
        } {
            param($ResourceType, $ErrorMessage)
            { Assert-AvmBicepScopedTestIsolation `
                    -Template @{ resources = @(@{ type = $ResourceType; name = 'test' }) } `
                    -Scope sub -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage $ErrorMessage
        }
    }

    It 'rejects cross-scope and linked nested operations' {
        InModuleScope 'Avm.Authoring' {
            $crossScope = @{
                resources = @(@{
                        type = 'Microsoft.Authorization/policyDefinitions'
                        scope = '[tenant()]'
                    })
            }
            { Assert-AvmBicepScopedTestIsolation -Template $crossScope `
                    -Scope sub -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*cross-scope*'
            $linked = @{
                resources = @(@{
                        type = 'Microsoft.Resources/deployments'
                        properties = @{ templateLink = @{ uri = 'https://example.invalid' } }
                    })
            }
            { Assert-AvmBicepScopedTestIsolation -Template $linked `
                    -Scope tenant -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*inline template*'
        }
    }

    It 'refuses <Case> nested deployment mode before Azure access' -ForEach @(
        @{ Case = 'Complete'; Mode = 'Complete' }
        @{ Case = 'dynamic'; Mode = '[parameters(''mode'')]' }
        @{ Case = 'missing'; Mode = $null }
        @{ Case = 'singleton array'; Mode = @('Incremental') }
        @{ Case = 'boolean'; Mode = $true }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ RequestedMode = $Mode } {
            param($RequestedMode)
            $template = @{
                resources = @(@{
                        type = 'Microsoft.Resources/deployments'
                        properties = @{
                            mode = $RequestedMode
                            template = @{
                                resources = @(@{
                                        type = 'Microsoft.Authorization/policyDefinitions'
                                    })
                            }
                        }
                    })
            }
            { Assert-AvmBicepScopedTestIsolation -Template $template `
                    -Scope mg -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*literal Incremental mode*'
        }
    }

    It 'refuses unreviewed nested property <Property>' -ForEach @(
        @{ Property = 'parametersLink'; Value = @{ uri = 'https://example.invalid/parameters.json' } }
        @{ Property = 'onErrorDeployment'; Value = @{ type = 'LastSuccessful' } }
        @{ Property = 'debugSetting'; Value = @{ detailLevel = 'requestContent' } }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            Name = $Property; Value = $Value
        } {
            param($Name, $Value)
            $properties = @{
                mode = 'Incremental'
                template = @{
                    resources = @(@{ type = 'Microsoft.Authorization/policyDefinitions' })
                }
            }
            $properties[$Name] = $Value
            { Assert-AvmBicepScopedTestIsolation -Template @{
                    resources = @(@{
                            type = 'Microsoft.Resources/deployments'
                            properties = $properties
                        })
                } -Scope sub -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage "*unsupported nested deployment property '$Name'*"
        }
    }

    It 'refuses non-inline parameters and outer expression evaluation' {
        InModuleScope 'Avm.Authoring' {
            $properties = @{
                mode = 'Incremental'
                template = @{
                    resources = @(@{ type = 'Microsoft.Authorization/policyDefinitions' })
                }
                parameters = '[parameters(''values'')]'
            }
            $template = @{ resources = @(@{
                        type = 'Microsoft.Resources/deployments'
                        properties = $properties
                    }) }
            { Assert-AvmBicepScopedTestIsolation -Template $template `
                    -Scope sub -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*inline nested deployment parameters*'

            $properties.parameters = @{}
            $properties.expressionEvaluationOptions = @{ scope = 'outer' }
            { Assert-AvmBicepScopedTestIsolation -Template $template `
                    -Scope sub -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*inner-scope nested expression evaluation*'

            $properties.expressionEvaluationOptions = @{ scope = @('inner') }
            { Assert-AvmBicepScopedTestIsolation -Template $template `
                    -Scope sub -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*inner-scope nested expression evaluation*'
        }
    }
}

Describe 'Bicep scoped e2e ownership predictions' {
    It 'parses exact new resources at subscription, management-group and tenant scopes' -ForEach @(
        @{ Scope = 'sub'; Prefix = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/' }
        @{ Scope = 'mg'; Prefix = '/providers/Microsoft.Management/managementGroups/avm-test/providers/' }
        @{ Scope = 'tenant'; Prefix = '/providers/' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            K = $Scope; P = $Prefix; S = $script:subscription; R = $script:runId
        } {
            param($K, $P, $S, $R)
            $id = "${P}Microsoft.Authorization/roleDefinitions/role-$($R.Substring(0, 10))"
            $json = @{
                changes = @(@{
                        resourceId = $id
                        changeType = 'Create'
                        after = @{
                            name = "role-$($R.Substring(0, 10))"
                            type = 'Microsoft.Authorization/roleDefinitions'
                        }
                    })
            } | ConvertTo-Json -Depth 8 -Compress
            $plan = Read-AvmBicepScopedWhatIf -Output $json -File 'case.bicep' `
                -Scope $K -SubscriptionId $S -ManagementGroupId 'avm-test' -RunId $R
            $plan.Resources.Count | Should -Be 1
            $plan.Resources[0].Id | Should -Be $id
            $plan.Resources[0].Kind | Should -Be 'Resource'
            $plan.Deployments.Count | Should -Be 0
        }
    }

    It 'requires a unique, tagged and new resource group at subscription scope' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            S = $script:subscription; R = $script:runId
        } {
            param($S, $R)
            $id = "/subscriptions/$S/resourceGroups/avm-$($R.Substring(0, 10))"
            $changes = @(@{
                    resourceId = $id
                    changeType = 'Create'
                    after = @{
                        name = "avm-$($R.Substring(0, 10))"
                        type = 'Microsoft.Resources/resourceGroups'
                        tags = @{ 'avm-e2e-run-id' = $R }
                    }
                })
            $json = @{ changes = $changes } | ConvertTo-Json -Depth 8 -Compress
            $plan = Read-AvmBicepScopedWhatIf -Output $json -File 'case.bicep' `
                -Scope sub -SubscriptionId $S -RunId $R
            $plan.Resources[0].Kind | Should -Be 'Group'
            $changes[0].after.tags['avm-e2e-run-id'] = 'another-run'
            $bad = @{ changes = $changes } | ConvertTo-Json -Depth 8 -Compress
            { Read-AvmBicepScopedWhatIf -Output $bad -File 'case.bicep' `
                    -Scope sub -SubscriptionId $S -RunId $R } |
                Should -Throw -ExpectedMessage '*ownership tag*'
        }
    }

    It 'refuses ambiguous or foreign what-if predictions' -ForEach @(
        @{ Kind = 'ignore'; Change = 'Ignore'; Id = '/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = @{}; Message = '*non-Create*' }
        @{ Kind = 'deploy'; Change = 'Deploy'; Id = '/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = @{}; Message = '*non-Create*' }
        @{ Kind = 'existing'; Change = 'NoChange'; Id = '/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = @{}; Message = '*non-Create*' }
        @{ Kind = 'foreign'; Change = 'Create'; Id = '/subscriptions/another/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = @{}; Message = '*outside the explicit*' }
        @{ Kind = 'nonunique'; Change = 'Create'; Id = '/providers/Microsoft.Authorization/policyDefinitions/static'; After = @{}; Message = '*run suffix*' }
        @{ Kind = 'unexpanded'; Change = 'Create'; Id = '/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = $null; Message = '*full resource payload*' }
        @{ Kind = 'missing-identity'; Change = 'Create'; Id = '/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = @{}; Message = '*inconsistent expanded resource*' }
        @{ Kind = 'wrong-identity'; Change = 'Create'; Id = '/providers/Microsoft.Authorization/policyDefinitions/avm-0123456789'; After = @{ name = 'avm-0123456789'; type = 'Microsoft.Authorization/policyDefinitions'; id = '/providers/Microsoft.Authorization/policyDefinitions/other' }; Message = '*inconsistent expanded resource*' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            C = $Change; I = $Id; A = $After; M = $Message
            S = $script:subscription; R = $script:runId
        } {
            param($C, $I, $A, $M, $S, $R)
            $json = @{ changes = @(@{
                        resourceId = $I; changeType = $C; after = $A
                    }) } | ConvertTo-Json -Depth 8 -Compress
            { Read-AvmBicepScopedWhatIf -Output $json -File 'case.bicep' `
                    -Scope tenant -SubscriptionId $S -RunId $R } |
                Should -Throw -ExpectedMessage $M
        }
    }

    It 'recognizes only explicit Azure not-found error codes' {
        InModuleScope 'Avm.Authoring' {
            (Test-AvmBicepAzNotFound -StdErr 'ERROR: (ResourceNotFound) missing') |
                Should -BeTrue
            (Test-AvmBicepAzNotFound -StdErr '(DeploymentNotFound) missing') |
                Should -BeTrue
            (Test-AvmBicepAzNotFound -StdErr 'ERROR: (AuthorizationFailed) forbidden') |
                Should -BeFalse
            (Test-AvmBicepAzNotFound -StdErr '') | Should -BeFalse
        }
    }
}
