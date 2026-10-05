#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepConventionSuite' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            # Two remaining family checks and one minimum native ownership check.
            $script:convention = @{
                Root            = $TestDrive
                RepositoryRoot  = $TestDrive
                Scopes          = @([pscustomobject]@{ Path = $TestDrive; IsTopLevel = $true })
                CompiledModules = @()
                Workflows       = @()
                TestSources     = @()
            }
            $script:summary = [pscustomobject]@{ Total = 3; Passed = 3; Failed = 0; Issues = @() }
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeVersionExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                $script:summary
            }
        }
    }

    It 'does not start Pester when there is nothing to check' {
        InModuleScope 'Avm.Authoring' {
            $script:convention.Scopes = @()
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Count | Should -Be 0
            Should -Invoke Invoke-AvmBicepPesterSuite -Times 0 -Exactly
        }
    }

    It 'returns recorded findings from a complete run in process' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeVersionExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                $ConventionData.Findings.Add([pscustomobject]@{ Code = 'avm.bicep.sample'; Severity = 'warning' })
                $script:summary
            }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.sample')
            Should -Invoke Invoke-AvmBicepPesterSuite -Times 1 -Exactly -ParameterFilter {
                $Mode -eq 'Convention' -and $InProcess -and
                $Files[0] -like '*Resources*bicep*conventions*Conventions.Tests.ps1'
            }
        }
    }

    It 'reports a rule crash as an error instead of throwing' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeVersionExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                $ConventionData.Crashes.Add([pscustomobject]@{ Rule = 'Layout'; Message = 'boom' })
                [pscustomobject]@{ Total = 3; Passed = 2; Failed = 1; Issues = @() }
            }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.convention-rule-failed')
            $issues[0].Severity | Should -Be 'error'
            $issues[0].Message | Should -Match "'Layout'.*boom"
        }
    }

    It 'never lets a failed test without a finding pass' {
        InModuleScope 'Avm.Authoring' {
            $script:summary = [pscustomobject]@{ Total = 3; Passed = 2; Failed = 1; Issues = @() }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.convention-rule-failed')
        }
    }

    It 'reports a run with fewer checks than expected as incomplete' {
        InModuleScope 'Avm.Authoring' {
            $script:summary = [pscustomobject]@{ Total = 2; Passed = 2; Failed = 0; Issues = @() }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues.Code | Should -Be @('avm.bicep.convention-suite-incomplete')
            $issues[0].Message | Should -Match '2 of 3'
        }
    }

    It 'preserves a mapped native advisory without hiding an unmapped failure' -TestCases @(
        @{ Failures = 1; HasUnmappedFailure = $false }
        @{ Failures = 2; HasUnmappedFailure = $true }
    ) {
        param($Failures, $HasUnmappedFailure)
        InModuleScope 'Avm.Authoring' -Parameters @{
            Failures = $Failures; HasUnmappedFailure = $HasUnmappedFailure
        } {
            param($Failures, $HasUnmappedFailure)
            $script:summary = [pscustomobject]@{
                Total = 3; Passed = 3 - $Failures; Failed = $Failures
                Issues = @(@{
                        NativeConvention = $true; Code = 'avm.bicep.parameter-untyped-object'
                        Severity = 'warning'; File = Join-Path $TestDrive 'main.bicep'
                        Message = 'Use an explicit object type.'; Line = 1
                    })
            }
            $issues = @(Invoke-AvmBicepConventionSuite -Convention $script:convention)
            $issues[0].Severity | Should -Be 'warning'
            $issues[0].File | Should -Be 'main.bicep'
            (@($issues | Where-Object { $_.Code -eq 'avm.bicep.convention-rule-failed' }).Count -gt 0) |
                Should -Be $HasUnmappedFailure
        }
    }

    It 'reports skipped checks as incomplete even when the total matches' {
        InModuleScope 'Avm.Authoring' {
            $script:summary = [pscustomobject]@{ Total = 3; Passed = 2; Failed = 0; Issues = @() }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'fails closed when native ownership discovery never registers its tests' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeVersionExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                [pscustomobject]@{ Total = 2; Passed = 2; Failed = 0; Issues = @() }
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'fails closed when child publication discovery never registers even with no versioned children' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeVersionExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                $script:summary
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'fails closed when version discovery never registers even with no version files' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                $script:summary
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'fails closed when compiled modules run without native API requirements' {
        InModuleScope 'Avm.Authoring' {
            $script:convention.CompiledModules = @([pscustomobject]@{
                    Path = Join-Path $TestDrive 'main.bicep'; Template = @{ resources = @() }
                })
            Mock Get-AvmBicepCompiledConventionInput { @{} }
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeCompiledExpected = 11
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeVersionExpected = 0
                $ConventionData.NativeTestSourceExpected = 0
                [pscustomobject]@{ Total = 14; Passed = 14; Failed = 0; Issues = @() }
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'fails closed when test-source discovery never registers even with no test files' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmBicepPesterSuite {
                $ConventionData.NativeOwnershipExpected = 1
                $ConventionData.NativeChildPublishExpected = 0
                $ConventionData.NativeVersionExpected = 0
                $script:summary
            }
            @(Invoke-AvmBicepConventionSuite -Convention $script:convention).Code |
                Should -Be @('avm.bicep.convention-suite-incomplete')
        }
    }

    It 'surfaces runner diagnostics other than ordinary test failures' {
        InModuleScope 'Avm.Authoring' {
            $script:summary = [pscustomobject]@{
                Total = 3; Passed = 3; Failed = 0
                Issues = @(
                    [pscustomobject]@{ Code = 'avm.bicep.pester-failed'; Message = 'ignored' },
                    [pscustomobject]@{ Code = 'avm.bicep.pester-container-failed'; Message = 'discovery failed' }
                )
            }
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
