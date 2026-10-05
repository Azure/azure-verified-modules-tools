#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-AvmBicepConventionSuite' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:convention = @{
                Root = $TestDrive; RepositoryRoot = $TestDrive
                Scopes = @([pscustomobject]@{ Path = $TestDrive; IsTopLevel = $true })
                CompiledModules = @(); Workflows = @(); TestSources = @()
                Publication = [pscustomobject]@{ Issues = @(); Entries = @(); Targets = @{} }
            }
            $script:summary = [pscustomobject]@{ Total = 2; Passed = 2; Failed = 0; Issues = @() }
            $script:registerNative = {
                param($Data)
                foreach ($name in @('Compiled', 'ApiVersion', 'Workflow', 'ChildPublish', 'Version', 'TestSource', 'Publication')) {
                    $Data["Native${name}Expected"] = 0
                }
                $Data.NativeOwnershipExpected = 1
                $Data.NativeLayoutExpected = 1
            }
            Mock Invoke-AvmBicepPesterSuite {
                & $script:registerNative $ConventionData
                $script:summary
            }
        }
    }

    It 'does not start Pester when there is nothing to check' {
        InModuleScope 'Avm.Authoring' {
            $script:convention.Scopes = @()
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention) | Should -HaveCount 0
            Should -Invoke Invoke-AvmBicepPesterSuite -Times 0 -Exactly
        }
    }

    It 'runs only native resource suites in process' {
        InModuleScope 'Avm.Authoring' {
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention) | Should -HaveCount 0
            Should -Invoke Invoke-AvmBicepPesterSuite -Times 1 -Exactly -ParameterFilter {
                $Mode -eq 'Convention' -and $InProcess -and $Files.Count -eq 6 -and
                @($Files | Where-Object { $_ -like '*Conventions.Tests.ps1' }).Count -eq 0 -and
                @($Files | Where-Object { $_ -like '*Layout.Tests.ps1' }).Count -eq 1 -and
                @($Files | Where-Object { $_ -like '*Publication.Tests.ps1' }).Count -eq 1
            }
        }
    }

    It 'preserves publication preparation failures without a family wrapper' {
        InModuleScope 'Avm.Authoring' {
            $script:convention.Publication.Issues = @([pscustomobject]@{
                    Code = 'avm.bicep.publication-git-state'; Severity = 'error'; Message = 'Untrusted upstream.'
                })
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.publication-git-state')
            $issues[0].Message | Should -BeExactly 'Untrusted upstream.'
        }
    }

    It 'never lets a failed test without a native finding pass' {
        InModuleScope 'Avm.Authoring' {
            $script:summary.Passed = 1
            $script:summary.Failed = 1
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-rule-failed')
        }
    }

    It 'reports fewer checks than expected' {
        InModuleScope 'Avm.Authoring' {
            $script:summary.Total = 1
            $script:summary.Passed = 1
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.convention-suite-incomplete')
            $issues[0].Message | Should -Match '1 of 2'
        }
    }

    It 'preserves a mapped native advisory without hiding an unmapped failure' -ForEach @(
        @{ Failures = 1; HasUnmappedFailure = $false }
        @{ Failures = 2; HasUnmappedFailure = $true }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Failures = $Failures; HasUnmappedFailure = $HasUnmappedFailure } {
            param($Failures, $HasUnmappedFailure)
            $script:summary = [pscustomobject]@{
                Total = 2; Passed = 2 - $Failures; Failed = $Failures
                Issues = @(@{
                        NativeConvention = $true; Code = 'avm.bicep.parameter-untyped-object'
                        Severity = 'warning'; File = Join-Path $TestDrive 'main.bicep'
                        Message = 'Use an explicit object type.'; Line = 17
                    })
            }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues[0].Severity | Should -Be 'warning'
            $issues[0].File | Should -Be 'main.bicep'
            $issues[0].Line | Should -Be 17
            (@($issues | Where-Object Code -eq 'avm.bicep.convention-rule-failed').Count -gt 0) |
                Should -Be $HasUnmappedFailure
        }
    }

    It 'reports skipped checks as incomplete even when totals match' {
        InModuleScope 'Avm.Authoring' {
            $script:summary.Passed = 1
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'rejects missing <Name> discovery independently of reported totals' -ForEach @(
        @{ Name = 'Ownership'; Value = 0; Total = 1 }
        @{ Name = 'ChildPublish'; Value = -1; Total = 2 }
        @{ Name = 'Version'; Value = -1; Total = 2 }
        @{ Name = 'TestSource'; Value = -1; Total = 2 }
        @{ Name = 'Layout'; Value = -1; Total = 1 }
        @{ Name = 'Publication'; Value = -1; Total = 2 }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Name = $Name; Value = $Value; Total = $Total } {
            param($Name, $Value, $Total)
            $script:missing = @{ Name = $Name; Value = $Value; Total = $Total }
            Mock Invoke-AvmBicepPesterSuite {
                & $script:registerNative $ConventionData
                $ConventionData["Native$($script:missing.Name)Expected"] = $script:missing.Value
                [pscustomobject]@{ Total = $script:missing.Total; Passed = $script:missing.Total; Failed = 0; Issues = @() }
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'rejects compiled modules without native API checks' {
        InModuleScope 'Avm.Authoring' {
            $script:convention.CompiledModules = @([pscustomobject]@{
                    Path = Join-Path $TestDrive 'main.bicep'; Template = @{ resources = @() }
                })
            Mock Get-AvmBicepCompiledConventionInput { @{} }
            Mock Invoke-AvmBicepPesterSuite {
                & $script:registerNative $ConventionData
                $ConventionData.NativeCompiledExpected = 11
                [pscustomobject]@{ Total = 13; Passed = 13; Failed = 0; Issues = @() }
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'rejects missing publication inputs without preparation diagnostics' {
        InModuleScope 'Avm.Authoring' {
            $script:convention.Publication.Entries = @([pscustomobject]@{
                    Scope = $script:convention.Scopes[0]; Target = $null; Published = $null
                })
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'surfaces failed-container diagnostics' {
        InModuleScope 'Avm.Authoring' {
            $script:summary.Issues = @(
                [pscustomobject]@{ Code = 'avm.bicep.pester-failed'; Message = 'ordinary failure' }
                [pscustomobject]@{ Code = 'avm.bicep.pester-container-failed'; Message = 'discovery failed' }
            )
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.convention-rule-failed')
            $issues[0].Message | Should -Match 'pester-container-failed: discovery failed'
        }
    }

    It 'explains how to install Pester when the suite cannot start' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite { throw [AvmProcessException]::new('Pester missing') }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.convention-suite-unavailable')
            $issues[0].Message | Should -Match 'Install-PSResource -Name Pester'
        }
    }
}

Describe 'Get-AvmBicepChildPublishAllowlist' {
    It 'reports an unreadable allowlist directory as a configuration error' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-ChildItem { throw [System.UnauthorizedAccessException]::new('denied') }
            { Get-AvmBicepChildPublishAllowlist -RepositoryRoot $TestDrive } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*denied*'
        }
    }
}
