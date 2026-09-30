#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '00000000-0000-0000-0000-000000000001'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep e2e static deployment isolation' {
    It 'accepts group resources and inspectable nested inline deployments' {
        InModuleScope 'Avm.Authoring' {
            $template = @{
                resources = @(
                    @{
                        type = 'Microsoft.Resources/deployments'
                        properties = @{
                            template = @{
                                resources = @(@{ type = 'Microsoft.Storage/storageAccounts'; name = 'storage' })
                            }
                        }
                    }
                )
            }
            { Assert-AvmBicepTestIsolation -Template $template -SourcePath 'case.bicep' } |
                Should -Not -Throw
        }
    }

    It 'rejects uninspectable nested resources, dynamic types and authorization resources' -ForEach @(
        @{ Resource = @{ type = "[parameters('type')]" }; Message = '*type that cannot be verified*' }
        @{ Resource = @{ type = 'Microsoft.Storage/storageAccounts'; resources = 'not-an-array' }; Message = '*cannot be inspected*' }
        @{ Resource = @{ type = 'Microsoft.Resources/deployments'; properties = @{ templateLink = @{ uri = 'https://example.invalid' } } }; Message = '*inline template*' }
        @{ Resource = @{ type = 'Microsoft.Authorization/roleAssignments' }; Message = '*cannot be safely contained*' }
        @{ Resource = @{ type = 'Microsoft.Storage/storageAccounts'; subscriptionId = 'another-subscription' }; Message = '*cross-scope*' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $Resource; M = $Message } {
            param($R, $M)
            { Assert-AvmBicepTestIsolation -Template @{ resources = @($R) } `
                    -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage $M
        }
    }

    It 'rejects templates without resources or with malformed resource entries' {
        InModuleScope 'Avm.Authoring' {
            { Assert-AvmBicepTestIsolation -Template @{ resources = @() } `
                    -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*no inspectable ARM resources*'
            { Assert-AvmBicepTestIsolation -Template @{ resources = @('bad') } `
                    -SourcePath 'case.bicep' } |
                Should -Throw -ExpectedMessage '*invalid ARM resource*'
        }
    }
}

Describe 'Bicep e2e ARM response verification' {
    It 'extracts what-if resource changes and accepts a confirmed deployment result' {
        InModuleScope 'Avm.Authoring' -Parameters @{ S = $script:subscription } {
            param($S)
            $change = @(Read-AvmBicepWhatIfChange `
                    -Output '{"changes":[{"resourceId":"/subscriptions/demo","changeType":"Create"}]}' `
                    -File 'case.bicep')
            $change.Count | Should -Be 1
            $change[0].File | Should -Be 'case.bicep'
            $change[0].ChangeType | Should -Be 'Create'

            $deployment = @{
                id = "/subscriptions/$S/resourceGroups/avm-test/providers/Microsoft.Resources/deployments/test"
                name = 'test'
                properties = @{ provisioningState = 'Succeeded' }
            } | ConvertTo-Json -Depth 8 -Compress
            { Assert-AvmBicepDeploymentSucceeded -Output $deployment -SubscriptionId $S `
                    -ResourceGroupName 'avm-test' -DeploymentName 'test' } |
                Should -Not -Throw
        }
    }

    It 'rejects invalid or missing what-if predictions' -ForEach @(
        @{ Output = 'not-json'; Message = '*invalid JSON*' }
        @{ Output = '{}'; Message = '*no JSON changes array*' }
        @{ Output = '{"changes":[{}]}'; Message = '*invalid change*' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ O = $Output; M = $Message } {
            param($O, $M)
            { Read-AvmBicepWhatIfChange -Output $O -File 'case.bicep' } |
                Should -Throw -ExpectedMessage $M
        }
    }

    It 'rejects missing, unrelated or unsuccessful deployment confirmations' -ForEach @(
        @{ Output = 'not-json'; Message = '*invalid JSON*' }
        @{ Output = '{}'; Message = '*did not confirm*' }
        @{ Output = '{"id":"/subscriptions/other","name":"test","properties":{"provisioningState":"Succeeded"}}'; Message = '*did not confirm*' }
        @{ Output = '{"id":"/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/avm-test/providers/Microsoft.Resources/deployments/test","name":"test","properties":{"provisioningState":"Failed"}}'; Message = '*did not confirm*' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            O = $Output; M = $Message; S = $script:subscription
        } {
            param($O, $M, $S)
            { Assert-AvmBicepDeploymentSucceeded -Output $O -SubscriptionId $S `
                    -ResourceGroupName 'avm-test' -DeploymentName 'test' } |
                Should -Throw -ExpectedMessage $M
        }
    }
}

Describe 'Bicep e2e ownership-verified cleanup' {
    It 'distinguishes a nonexistent failed creation from an unverified successful creation' {
        InModuleScope 'Avm.Authoring' -Parameters @{ S = $script:subscription } {
            param($S)
            Mock Test-AvmBicepResourceGroup { $false }
            Mock Invoke-AvmProcess { throw 'No Azure command should be needed' }
            $args = @{
                AzPath = 'fake-az'
                SubscriptionId = $S
                ResourceGroupName = 'avm-test'
                RunId = 'test-run'
                WorkingDirectory = '.'
            }
            (Remove-AvmBicepTestResourceGroup @args).Cleaned | Should -BeTrue
            $pending = Remove-AvmBicepTestResourceGroup @args -ExpectCreated
            $pending.Cleaned | Should -BeFalse
            $pending.Message | Should -Match 'manual cleanup verification'
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'does not delete an owned group when WhatIf declines removal' {
        InModuleScope 'Avm.Authoring' -Parameters @{ S = $script:subscription } {
            param($S)
            Mock Test-AvmBicepResourceGroup { $true }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[1] -eq 'delete') {
                    throw 'Deletion must not run'
                }
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = (@{
                            id = "/subscriptions/$S/resourceGroups/avm-test"
                            name = 'avm-test'
                            tags = @{ 'avm-e2e-run-id' = 'test-run' }
                        } | ConvertTo-Json -Compress)
                    StdErr = ''
                }
            }
            $result = Remove-AvmBicepTestResourceGroup -AzPath 'fake-az' `
                -SubscriptionId $S -ResourceGroupName 'avm-test' -RunId 'test-run' `
                -WorkingDirectory '.' -WhatIf
            $result.Cleaned | Should -BeFalse
            $result.Message | Should -Match 'declined'
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[1] -eq 'delete'
            }
        }
    }

    It 'rejects malformed Azure CLI existence results' {
        InModuleScope 'Avm.Authoring' -Parameters @{ S = $script:subscription } {
            param($S)
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = 'unknown'; StdErr = '' }
            }
            { Test-AvmBicepResourceGroup -AzPath 'fake-az' -SubscriptionId $S `
                    -ResourceGroupName 'avm-test' -WorkingDirectory '.' } |
                Should -Throw -ExpectedMessage '*invalid resource-group existence result*'
        }
    }
}
