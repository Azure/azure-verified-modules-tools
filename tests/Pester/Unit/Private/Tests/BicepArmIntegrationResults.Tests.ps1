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

Describe 'Bicep ARM integration result handling' {
    It 'reports no runnable tests as skipped without resolving tools or credentials' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            Mock Get-AvmBicepTestCase { @() }
            Mock Resolve-AvmTool { throw 'Tool must not be resolved' }
            $context = [pscustomobject]@{ Root = $R; Ecosystem = 'bicep' }
            $result = Invoke-AvmBicepTestIntegration -Context $context
            $result.Status | Should -Be 'skipped'
            $result.RunsTotal | Should -Be 0
            $result.FilesProcessed | Should -Be 0
            Should -Invoke Resolve-AvmTool -Exactly 0
        }
    }

    It 'rejects a missing explicit subscription before resolving Azure tools' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            Mock Get-AvmBicepTestCase {
                [pscustomobject]@{
                    Name = 'defaults'; Path = 'fake.bicep'; RelativePath = 'tests/e2e/defaults/main.test.bicep'
                    RelativeDirectory = 'tests/e2e/defaults'; Ignored = $false
                }
            }
            Mock Resolve-AvmTool { throw 'Tool must not be resolved' }
            $context = [pscustomobject]@{ Root = $R; Ecosystem = 'bicep' }
            { Invoke-AvmBicepTestIntegration -Context $context } |
                Should -Throw -ExpectedMessage '*explicit*SubscriptionId*'
            Should -Invoke Resolve-AvmTool -Exactly 0
        }
    }

    It 'aggregates validate and what-if outcomes, including a skipped operation after failure' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $TestDrive; S = $script:subscription
        } {
            param($R, $S)
            $script:failArmValidation = $false
            Mock Get-AvmBicepTestCase {
                [pscustomobject]@{
                    Name = 'defaults'; Path = 'fake.bicep'; RelativePath = 'tests/e2e/defaults/main.test.bicep'
                    RelativeDirectory = 'tests/e2e/defaults'; Ignored = $false
                }
            }
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Path = 'fake-bicep'; Version = 'pinned' }
            }
            Mock Get-Command {
                [pscustomobject]@{ Source = 'fake-az' }
            } -ParameterFilter { $Name -eq 'az' }
            Mock New-AvmBicepTestTemplate {
                [pscustomobject]@{ Scope = 'group'; Path = $DestinationPath; Template = @{} }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
            }
            Mock Invoke-AvmBicepArmOperation {
                if ($script:failArmValidation -and $Operation -eq 'Validate') {
                    return [pscustomobject]@{
                        ExitCode = 1; StdOut = ''; StdErr = 'Validation rejected'
                    }
                }
                $output = if ($Operation -eq 'WhatIf') {
                    '{"changes":[{"resourceId":"/subscriptions/test/resourceGroups/example/providers/Test/resource/a","changeType":"Create"}]}'
                }
                else { '{"status":"Succeeded"}' }
                [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
            }
            $context = [pscustomobject]@{ Root = $R; Ecosystem = 'bicep' }
            $passed = Invoke-AvmBicepTestIntegration -Context $context `
                -SubscriptionId $S -ResourceGroupName 'existing-group'
            $passed.Status | Should -Be 'pass'
            $passed.RunsPassed | Should -Be 2
            $passed.WhatIfChanges.Count | Should -Be 1

            $script:failArmValidation = $true
            $failed = Invoke-AvmBicepTestIntegration -Context $context `
                -SubscriptionId $S -ResourceGroupName 'existing-group'
            $failed.Status | Should -Be 'fail'
            $failed.RunsTotal | Should -Be 1
            $failed.RunsFailed | Should -Be 1
            $failed.RunsSkipped | Should -Be 1
            $failed.Issues[0].Message | Should -Match 'Validation rejected'
        }
    }
}
