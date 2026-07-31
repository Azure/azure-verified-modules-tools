#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Write-AvmResult GitHub summary' {
    It 'appends the rendered result when GitHub Actions is active' {
        $summaryPath = Join-Path $TestDrive 'summary.md'
        $oldActions = $env:GITHUB_ACTIONS
        $oldSummary = $env:GITHUB_STEP_SUMMARY
        try {
            $env:GITHUB_ACTIONS = 'true'
            $env:GITHUB_STEP_SUMMARY = $summaryPath
            InModuleScope 'Avm.Authoring' {
                $result = [pscustomobject]@{
                    Status = 'fail'
                    Issues = @([pscustomobject]@{
                            Severity = 'error'; File = 'main.tf'; Line = 1; Column = 2
                            Code = 'avm.test'; Message = 'summary detail'
                        })
                }
                Write-AvmResult -Result $result -Verb 'lint'
            } 6>$null

            $summary = Get-Content -LiteralPath $summaryPath -Raw
            $summary | Should -Match 'avm lint'
            $summary | Should -Match 'main\.tf:1:2'
            $summary | Should -Match 'summary detail'
        }
        finally {
            $env:GITHUB_ACTIONS = $oldActions
            $env:GITHUB_STEP_SUMMARY = $oldSummary
        }
    }
}

Describe 'ConvertTo-AvmRunSummaryLine' {
    It 'F33: renders the run tally when the result carries run counts' {
        InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'pass'; FilesProcessed = 4
                RunsTotal = 14; RunsPassed = 14; RunsFailed = 0
            }
            $lines = @(ConvertTo-AvmResultDetailLine -Result $result)
            $lines | Should -Contain '  14 runs, 14 passed, 0 failed'
        }
    }

    It 'F33: emits nothing for results without run counts' {
        InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{ Status = 'pass'; FilesProcessed = 4 }
            @(ConvertTo-AvmRunSummaryLine -Result $result) | Should -BeNullOrEmpty
        }
    }

    It 'F33: renders the tally for a gauntlet step result' {
        InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'pass'
                Steps  = @([pscustomobject]@{
                        Step   = 'unit'
                        Status = 'pass'
                        Result = [pscustomobject]@{
                            RunsTotal = 3; RunsPassed = 2; RunsFailed = 1
                        }
                    })
            }
            $lines = @(ConvertTo-AvmResultDetailLine -Result $result)
            ($lines -join "`n") | Should -Match '3 runs, 2 passed, 1 failed'
        }
    }
}
