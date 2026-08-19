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

    It 'colours failed steps red and passing steps green without annotations' {
        $oldActions = $env:GITHUB_ACTIONS
        $oldColorForce = $env:CLICOLOR_FORCE
        try {
            $env:GITHUB_ACTIONS = ''
            $env:CLICOLOR_FORCE = '1'
            $messages = InModuleScope 'Avm.Authoring' {
                $captured = @()
                $result = [pscustomobject]@{
                    Status = 'fail'
                    Steps = @(
                        [pscustomobject]@{ Step = 'sync'; Status = 'fail'; Error = 'managed file is stale' }
                        [pscustomobject]@{ Step = 'format'; Status = 'pass'; Error = $null }
                    )
                }
                Write-AvmResult -Result $result -Verb 'pr-check' -InformationVariable captured
                @($captured | ForEach-Object { [string]$_.MessageData })
            }

            $escape = [char]27
            @($messages) | Should -Contain "$escape[31m  [fail] sync$escape[0m"
            @($messages) | Should -Contain "$escape[31m    managed file is stale$escape[0m"
            @($messages) | Should -Contain "$escape[32m  [pass] format$escape[0m"
            @($messages | Where-Object { $_ -like '::error*' }).Count | Should -Be 0
        }
        finally {
            $env:GITHUB_ACTIONS = $oldActions
            $env:CLICOLOR_FORCE = $oldColorForce
        }
    }

    It 'omits an already-presented issue only from final output and keeps it in the result contract' {
        $probe = InModuleScope 'Avm.Authoring' {
            $issue = [pscustomobject]@{
                Severity = 'notice'
                File     = 'variables.tf'
                Line     = 17
                Column   = 5
                Code     = 'deprecated_lock_interface'
                Message  = 'Use the canonical lock interface.'
            }
            $lint = [pscustomobject]@{
                Status = 'pass'
                Issues = @($issue)
            }
            $result = [pscustomobject]@{
                Status = 'pass'
                Steps  = @([pscustomobject]@{
                        Step = 'lint'; Status = 'pass'; Result = $lint
                    })
            }
            Register-AvmPresentedIssue -Issue $issue
            $ordinaryLines = @(ConvertTo-AvmResultLine -Result $result -Verb 'pr-check')
            Mock Write-AvmLog
            Write-AvmResult -Result $result -Verb 'pr-check'

            Should -Invoke Write-AvmLog -Exactly 0 -ParameterFilter {
                $Message -match 'deprecated_lock_interface|canonical lock'
            }
            [pscustomobject]@{
                OrdinaryLines = $ordinaryLines
                Json          = $result | ConvertTo-Json -Depth 10
            }
        }

        ($probe.OrdinaryLines -join "`n") | Should -Match 'deprecated_lock_interface'
        $probe.Json | Should -Match 'deprecated_lock_interface'
        $probe.Json | Should -Not -Match 'Presented|Inline|Reported'
    }
}

Describe 'ConvertTo-AvmResultLine' {
    It 'uses the plural result noun for multiple results' {
        InModuleScope 'Avm.Authoring' {
            $results = @(
                [pscustomobject]@{ Status = 'pass'; Name = 'first' }
                [pscustomobject]@{ Status = 'pass'; Name = 'second' }
            )
            $lines = @(ConvertTo-AvmResultLine -Result $results -Verb 'lint')
            $lines[0] | Should -Be 'avm lint: 2 results'
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

    It 'uses a singular run noun for a single run' {
        InModuleScope 'Avm.Authoring' {
            $result = [pscustomobject]@{
                Status = 'pass'; RunsTotal = 1; RunsPassed = 1; RunsFailed = 0
            }
            $lines = @(ConvertTo-AvmResultDetailLine -Result $result)
            $lines | Should -Contain '  1 run, 1 passed, 0 failed'
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
