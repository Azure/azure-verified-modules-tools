#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmFailureDetail' {
    It 'headlines the positional diagnostic ahead of a bare status issue' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @(
                    [pscustomobject]@{
                        Severity = 'error'
                        File     = 'tests/integration/deploy.tftest.hcl'
                        Line     = 0
                        Column   = 0
                        Message  = "test run 'apply' fail"
                    },
                    [pscustomobject]@{
                        Severity = 'error'
                        File     = 'tests/integration/deploy.tftest.hcl'
                        Line     = 17
                        Column   = 21
                        Message  = 'Test assertion failed - condition was false'
                    }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match 'deploy\.tftest\.hcl:17:21'
        $detail | Should -Match 'Test assertion failed'
        $detail | Should -Not -Match "test run 'apply' fail"
    }

    It 'falls back to the first issue when none carry a position' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @(
                    [pscustomobject]@{ Severity = 'error'; Message = 'first problem' },
                    [pscustomobject]@{ Severity = 'error'; Message = 'second problem' }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match 'first problem'
    }

    It 'headlines the positional diagnostic from a failing chain step' {
        $detail = InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'fail'
                Steps  = @(
                    [pscustomobject]@{ Step = 'lint'; Status = 'pass'; Result = $null },
                    [pscustomobject]@{
                        Step   = 'test'
                        Status = 'fail'
                        Result = [pscustomobject]@{
                            Issues = @(
                                [pscustomobject]@{ Severity = 'error'; Line = 0; Message = "test run 'apply' fail" },
                                [pscustomobject]@{ Severity = 'error'; File = 'main.tf'; Line = 4; Column = 2; Message = 'Unsupported argument' }
                            )
                        }
                    }
                )
            }
            Get-AvmFailureDetail -Result $result
        }
        $detail | Should -Match "Step 'test'"
        $detail | Should -Match 'main\.tf:4:2'
        $detail | Should -Match 'Unsupported argument'
    }

    It 'returns an empty string when there is nothing to report' {
        $detail = InModuleScope 'Avm.Authoring' {
            Get-AvmFailureDetail -Result ([pscustomobject]@{ Status = 'fail' })
        }
        $detail | Should -BeExactly ''
    }
}