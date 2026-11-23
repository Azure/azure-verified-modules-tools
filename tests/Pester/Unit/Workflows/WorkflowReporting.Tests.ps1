#Requires -Version 7.4

BeforeAll {
    $script:reportRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:reportModule = Import-Module (Join-Path $script:reportRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $script:reportPath = Join-Path $script:reportRoot 'scripts' 'workflow-reporting' 'Invoke-AvmWorkflowReport.ps1'

    function Invoke-TestWorkflowReport {
        param([string] $EventName = 'pull_request', [string] $RequireE2e = 'true', [switch] $Preview)
        $parameters = @{
            Ecosystem = $script:ecosystem
            ResultsJson = ConvertTo-Json -InputObject $script:results -Depth 20
            Event = $script:event
            EventName = $EventName
            RequireE2e = $RequireE2e
            Repository = $script:repository
            SummaryPath = $script:summaryPath
            ServerUrl = 'https://github.com'
            RunId = '123'
            WhatIf = $Preview
        }
        & $script:reportModule {
            param($Path, $Parameters)
            . $Path
            Invoke-AvmWorkflowReport @Parameters
        } $script:reportPath $parameters
    }

    function Set-TestWorkflowSelection {
        param([bool] $Required = $true, [bool] $Authorized = $true, [bool] $Optional = $false, [bool] $HasOptional = $true)
        $outputs = if ($script:ecosystem -ceq 'terraform') { $script:results['discover-examples'].outputs }
        else { $script:results.initialize.outputs }
        if ($script:ecosystem -ceq 'terraform') {
            $outputs.requiredExamples = if ($Required) { '["default"]' } else { '[]' }
            $outputs.optionalExamples = if ($HasOptional) { '["private"]' } else { '[]' }
            $outputs.runRequired = $Authorized.ToString().ToLowerInvariant()
            $outputs.runOptional = $Optional.ToString().ToLowerInvariant()
        }
        else {
            $outputs.hasRequiredModules = $Required.ToString().ToLowerInvariant()
            $outputs.hasOptionalModules = $HasOptional.ToString().ToLowerInvariant()
            $outputs.requiredRequested = $Authorized.ToString().ToLowerInvariant()
            $outputs.optionalRequested = $Optional.ToString().ToLowerInvariant()
        }
        $labels = @(if ($Optional) { @{ name = 'PR: Run All E2E Tests' } }
            elseif ($Authorized) { @{ name = 'PR: Run Required E2E Tests' } })
        $script:event.pull_request.labels = $labels
        $script:api.Labels = $labels
    }
}

Describe 'Shared AVM workflow reporting' {
    Context '<Ecosystem>' -ForEach @(@{ Ecosystem = 'terraform' }, @{ Ecosystem = 'bicep' }) {
        BeforeEach {
            $script:ecosystem = $Ecosystem
            $script:repository = 'Azure/module'
            $script:summaryPath = Join-Path $TestDrive "$([guid]::NewGuid()).md"
            $script:event = @{ pull_request = @{
                    number = 42; head = @{ sha = 'current'; repo = @{ full_name = 'Azure/module' } }; labels = @()
                } }
            $script:results = @{
                bootstrap = @{ result = 'success' }
                subscriptions = @{ result = 'success' }
                'unit-test' = @{ result = 'success' }
                'pr-check' = @{ result = 'success' }
                'integration-test' = @{ result = 'success' }
                'discover-examples' = @{ result = 'success'; outputs = @{} }
                'select-e2e-tests' = @{ result = 'success'; outputs = @{ deploymentMatrix = '[{"Name":"default"}]' } }
                'e2e-test' = @{ result = 'success' }
                initialize = @{ result = 'success'; outputs = @{
                        hasModules = 'true'; requiredErrors = '[]'
                        moduleMatrix = '{"include":[{"modulePath":"avm/res/test/resource"}]}'
                    } }
                check = @{ result = 'success' }
            }
            $script:marker = if ($Ecosystem -ceq 'terraform') { '<!-- avm-terraform-e2e-label -->' }
            else { '<!-- avm-bicep-required-e2e-label-feedback -->' }
            $script:api = @{
                Calls = [Collections.Generic.List[object]]::new()
                Messages = [Collections.Generic.List[string]]::new()
                Comments = @(); SecondPage = @(); Head = 'current'; Labels = @(); Status = 0; TransportFailure = $false
            }
            Mock -ModuleName Avm.Authoring Write-Host { $script:api.Messages.Add([string]$Object) }
            Mock -ModuleName Avm.Authoring Invoke-AvmProcess { throw 'Unexpected subprocess in workflow reporting unit tests.' }
            Mock -ModuleName Avm.Authoring Invoke-AvmGitHubApi {
                param($Endpoint, $Method = 'GET', $Body)
                $test = $script:api
                $test.Calls.Add(@{ Endpoint = $Endpoint; Method = $Method; Body = $Body })
                if ($test.TransportFailure) { throw [InvalidOperationException]::new('Transport failed.') }
                if ($test.Status -ne 0) {
                    $exception = & $script:reportModule { param($Status) [AvmGitHubException]::new('API denied.', $Status) } $test.Status
                    throw $exception
                }
                if ($Endpoint -like '*/pulls/*') { return @{ head = @{ sha = $test.Head }; labels = $test.Labels } }
                if ($Endpoint -like '*comments?*page=2') { return $test.SecondPage }
                if ($Method -ceq 'GET') { return $test.Comments }
                return @{}
            }
            Set-TestWorkflowSelection
        }

        It 'passes successful checks without creating an unnecessary comment' {
            $report = Invoke-TestWorkflowReport
            $report.Passed | Should -BeTrue
            $report.CommentPublished | Should -BeFalse
            @($script:api.Calls | Where-Object Method -NE GET) | Should -HaveCount 0
        }

        It 'blocks missing authorization and explains both labels and the fork handoff' {
            Set-TestWorkflowSelection -Authorized $false
            $report = Invoke-TestWorkflowReport
            $report.Passed | Should -BeFalse
            $report.RequiredLabelMissing | Should -BeTrue
            $report.CommentPublished | Should -BeTrue
            $body = $script:api.Calls[-1].Body.body
            $body | Should -Match '`PR: Run Required E2E Tests`'
            $body | Should -Match '`PR: Run All E2E Tests`'
            $body | Should -Match 'required scenarios only'
            $body | Should -Match 'required and optional scenarios'
            $body | Should -Match 'release-branch handoff'
            $body | Should -Match '\[View PR-check run\]'
            Get-Content -LiteralPath $script:summaryPath -Raw | Should -Match 'Merging is blocked'
        }

        It 'updates only bot-owned marked comments and preserves human comments' -ForEach @(
            @{ Login = 'github-actions[bot]'; Expected = 'PATCH' }
            @{ Login = 'contributor'; Expected = 'POST' }
        ) {
            Set-TestWorkflowSelection -Authorized $false
            $script:api.Comments = @(@{ id = 7; user = @{ login = $Login }; body = "$script:marker`nprevious" })
            $null = Invoke-TestWorkflowReport
            $script:api.Calls[-1].Method | Should -BeExactly $Expected
        }

        It 'resolves a prior comment without claiming tests passed when either label is applied' -ForEach @(
            @{ Optional = $false }, @{ Optional = $true }
        ) {
            Set-TestWorkflowSelection -Optional $Optional
            $script:api.Comments = @(@{ id = 7; user = @{ login = 'github-actions[bot]' }; body = "$script:marker`nprevious" })
            $null = Invoke-TestWorkflowReport
            $script:api.Calls[-1].Method | Should -BeExactly 'PATCH'
            $script:api.Calls[-1].Body.body | Should -Match 'does not mean validation has passed'
        }

        It 'reports optional-only and absent examples without blocking an otherwise valid gate' -ForEach @(
            @{ HasOptional = $true }, @{ HasOptional = $false }
        ) {
            Set-TestWorkflowSelection -Required $false -Authorized $false -HasOptional $HasOptional
            $report = Invoke-TestWorkflowReport
            $report.Passed | Should -BeTrue
            $body = $script:api.Calls[-1].Body.body
            $body | Should -Match 'absence does not currently block merging'
            if ($HasOptional) { $body | Should -Match 'selects no tests here' }
            else { $body | Should -Match 'Labels cannot run examples that do not exist' }
        }

        It 'requires selected optional tests to pass rather than treating selection as validation' {
            Set-TestWorkflowSelection -Required $false -Optional $true
            if ($Ecosystem -ceq 'terraform') { $script:results['e2e-test'].result = 'failure' }
            else { $script:results.check.result = 'failure' }
            $report = Invoke-TestWorkflowReport
            $report.Passed | Should -BeFalse
            $script:api.Calls[-1].Body.body | Should -Match 'selection does not mean validation passed'
        }

        It 'rejects failed, cancelled and skipped checks' -ForEach @(
            @{ Result = 'failure' }, @{ Result = 'cancelled' }, @{ Result = 'skipped' }
        ) {
            $jobs = if ($Ecosystem -ceq 'terraform') { @('bootstrap', 'subscriptions', 'unit-test', 'pr-check', 'integration-test') }
            else { @('check') }
            foreach ($job in $jobs) {
                $script:results[$job].result = $Result
                (Invoke-TestWorkflowReport).Passed | Should -BeFalse -Because "$job was $Result"
                $script:results[$job].result = 'success'
            }
        }

        It 'uses exactly one of the Bicep upstream or fork check routes' {
            if ($Ecosystem -cne 'bicep') { return }
            $script:results['check-fork'] = @{ result = 'skipped' }
            (Invoke-TestWorkflowReport).Passed | Should -BeTrue

            $script:results.check.result = 'skipped'
            $script:results['check-fork'].result = 'success'
            (Invoke-TestWorkflowReport).Passed | Should -BeTrue

            $script:results.check.result = 'success'
            (Invoke-TestWorkflowReport).Passed | Should -BeFalse

            $script:results.check.result = 'skipped'
            $script:results['check-fork'].result = 'skipped'
            (Invoke-TestWorkflowReport).Passed | Should -BeFalse
        }

        It 'enforces selected E2E outcomes and initializer coverage errors' -ForEach @(
            @{ Result = 'failure' }, @{ Result = 'cancelled' }, @{ Result = 'skipped' }
        ) {
            if ($Ecosystem -ceq 'terraform') {
                foreach ($job in @('select-e2e-tests', 'e2e-test')) {
                    $script:results[$job].result = $Result
                    (Invoke-TestWorkflowReport).Passed | Should -BeFalse -Because "$job was $Result"
                    $script:results[$job].result = 'success'
                }
                $script:results['select-e2e-tests'].outputs.deploymentMatrix = '[]'
                $script:results['e2e-test'].result = 'skipped'
                (Invoke-TestWorkflowReport).Passed | Should -BeTrue
            }
            else {
                $script:results.initialize.outputs.requiredErrors = '["defaults is ignored"]'
                (Invoke-TestWorkflowReport).Passed | Should -BeFalse
            }
        }

        It 'never calls GitHub for a fork, even with deployment labels' {
            Set-TestWorkflowSelection -Authorized $false
            $script:event.pull_request.head.repo.full_name = 'contributor/module'
            $script:event.pull_request.labels = @(@{ name = 'PR: Run All E2E Tests' })
            (Invoke-TestWorkflowReport).Passed | Should -BeFalse
            $script:api.Calls | Should -HaveCount 0
            Get-Content -LiteralPath $script:summaryPath -Raw | Should -Match 'release-branch handoff'
        }

        It 'does not mutate comments when the head or labels changed after the event' -ForEach @(
            @{ Change = 'head' }, @{ Change = 'required' }, @{ Change = 'all' }
        ) {
            Set-TestWorkflowSelection -Authorized $false
            if ($Change -ceq 'head') { $script:api.Head = 'newer' }
            elseif ($Change -ceq 'required') { $script:api.Labels = @(@{ name = 'PR: Run Required E2E Tests' }) }
            else { $script:api.Labels = @(@{ name = 'PR: Run All E2E Tests' }) }
            $null = Invoke-TestWorkflowReport
            $script:api.Calls | Should -HaveCount 1
            $script:api.Messages -join "`n" | Should -Match 'Skipped stale'
        }

        It 'paginates comments before deciding whether to create another' {
            Set-TestWorkflowSelection -Authorized $false
            $script:api.Comments = @(1..100 | ForEach-Object { @{ id = $_; user = @{ login = 'contributor' }; body = 'Discussion' } })
            $script:api.SecondPage = @(@{ id = 101; user = @{ login = 'github-actions[bot]' }; body = "$script:marker`nprevious" })
            $null = Invoke-TestWorkflowReport
            $script:api.Calls[-1].Method | Should -BeExactly 'PATCH'
            $script:api.Calls[-1].Endpoint | Should -Match '/comments/101$'
        }

        It 'does not rewrite an unchanged comment on rerun' {
            Set-TestWorkflowSelection -Authorized $false
            $null = Invoke-TestWorkflowReport
            $body = $script:api.Calls[-1].Body.body
            $script:api.Comments = @(@{ id = 7; user = @{ login = 'github-actions[bot]' }; body = $body })
            $script:api.Calls.Clear()
            (Invoke-TestWorkflowReport).CommentPublished | Should -BeFalse
            @($script:api.Calls | Where-Object Method -NE GET) | Should -HaveCount 0
        }

        It 'keeps denied comments visible without changing the existing gate result' -ForEach @(
            @{ Authorized = $true }, @{ Authorized = $false }
        ) {
            Set-TestWorkflowSelection -Authorized $Authorized
            $script:api.Status = 403
            (Invoke-TestWorkflowReport).Passed | Should -Be $Authorized
            Get-Content -LiteralPath $script:summaryPath -Raw | Should -Match 'HTTP 403'
        }

        It 'does not swallow other API or transport errors' -ForEach @(
            @{ Status = 401; Transport = $false }
            @{ Status = 500; Transport = $false }
            @{ Status = 0; Transport = $true }
        ) {
            $script:api.Status = $Status
            $script:api.TransportFailure = $Transport
            $expected = if ($Transport) { '*Transport failed*' } else { '*API denied*' }
            { Invoke-TestWorkflowReport } | Should -Throw $expected
        }

        It 'keeps previews non-writing and never calls the API' {
            $report = Invoke-TestWorkflowReport -Preview
            $report.Passed | Should -BeTrue
            Test-Path -LiteralPath $script:summaryPath | Should -BeFalse
            $script:api.Calls | Should -HaveCount 0
        }

        It 'does not call the comment API for manual runs or unsupported events' {
            (Invoke-TestWorkflowReport -EventName workflow_dispatch).Passed | Should -BeTrue
            (Invoke-TestWorkflowReport -EventName merge_group).Passed | Should -BeFalse
            $script:api.Calls | Should -HaveCount 0
        }

        It 'fails closed on malformed results rather than reporting no required tests' {
            $script:results.Clear()
            { Invoke-TestWorkflowReport } | Should -Throw '*job result*'
        }

        It 'normalizes ecosystem casing without changing its gate policy' {
            $script:ecosystem = $Ecosystem.ToUpperInvariant()
            (Invoke-TestWorkflowReport).Passed | Should -BeTrue
        }

        It 'rejects malformed E2E enforcement flags instead of disabling enforcement' {
            { Invoke-TestWorkflowReport -RequireE2e TRUE } | Should -Throw '*RequireE2e*'
        }

        It 'escapes annotation commands including embedded newlines' {
            & $script:reportModule {
                param($Path)
                . $Path
                Write-AvmReportAnnotation -Level error -Message "Failure 100%`n::notice::spoof"
            } $script:reportPath
            $script:api.Messages[-1] | Should -BeExactly '::error::Failure 100%25%0A::notice::spoof'
        }

        It 'does not resolve feedback after failed discovery or initialization' {
            if ($Ecosystem -ceq 'terraform') { $script:results['discover-examples'].result = 'failure' }
            else { $script:results.initialize.result = 'failure' }
            (Invoke-TestWorkflowReport).Passed | Should -BeFalse
            $script:api.Calls | Should -HaveCount 0
        }

        It 'preserves template, no-module and manual static-only exemptions' {
            if ($Ecosystem -ceq 'terraform') {
                $script:repository = 'Azure/terraform-azurerm-avm-template'
                Set-TestWorkflowSelection -Authorized $false
            }
            else {
                $script:results.initialize.outputs.hasModules = 'false'
                $script:results.check.result = 'skipped'
            }
            (Invoke-TestWorkflowReport).Passed | Should -BeTrue
            $script:api.Calls | Should -HaveCount 0
            if ($Ecosystem -ceq 'bicep') {
                $script:results.initialize.outputs.hasModules = 'true'
                $script:results.check.result = 'success'
                $script:results.initialize.outputs.requiredErrors = '["ignored"]'
                (Invoke-TestWorkflowReport -EventName workflow_dispatch -RequireE2e false).Passed | Should -BeTrue
            }
        }

    }
}

Describe 'Shared reporting action trust boundary' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:reportActionPath = Join-Path $script:reportRoot '.github' 'actions' 'report-check-status'
        $script:reportAction = Get-Content -LiteralPath (Join-Path $script:reportActionPath 'action.yml') -Raw | ConvertFrom-Yaml
    }

    It 'loads the implementation from trusted action source without a checkout or expression interpolation' {
        $step = $script:reportAction.runs.steps[0]
        @($script:reportAction.runs.steps) | Should -HaveCount 1
        $step.shell | Should -BeExactly pwsh
        $step.run | Should -Match '\$env:GITHUB_ACTION_PATH'
        $step.run | Should -Match 'Avm\.Authoring\.psd1'
        $step.run | Should -Match 'Invoke-AvmWorkflowReport\.ps1'
        $step.run | Should -Not -Match '\$\{\{|checkout|GITHUB_WORKSPACE'
        $step.env.REPORT_RESULTS | Should -BeExactly '${{ inputs.results }}'
        $step.env.GH_TOKEN | Should -BeExactly '${{ inputs.token }}'
    }

    It 'returns the actual gate exit status from its source action runner' -ForEach @(
        @{ Status = 'success'; ExpectedExitCode = 0 }
        @{ Status = 'failure'; ExpectedExitCode = 1 }
    ) {
        $runner = Join-Path $TestDrive "$([guid]::NewGuid()).ps1"
        $summary = Join-Path $TestDrive "$([guid]::NewGuid()).md"
        [IO.File]::WriteAllText($runner, $script:reportAction.runs.steps[0].run, [Text.UTF8Encoding]::new($false))
        $needs = @{}
        foreach ($job in @('bootstrap', 'subscriptions', 'unit-test', 'pr-check', 'integration-test',
                'discover-examples', 'select-e2e-tests', 'e2e-test')) {
            $needs[$job] = @{ result = 'success' }
        }
        $needs['pr-check'].result = $Status
        $environment = @{
            REPORT_ECOSYSTEM = 'terraform'; REPORT_RESULTS = (ConvertTo-Json $needs -Depth 10); REPORT_REQUIRE_E2E = 'true'
            GITHUB_ACTION_PATH = $script:reportActionPath; GITHUB_EVENT_NAME = 'workflow_dispatch'
            GITHUB_REPOSITORY = 'Azure/terraform-azurerm-avm-template'; GITHUB_STEP_SUMMARY = $summary
            GITHUB_SERVER_URL = 'https://github.com'; GITHUB_RUN_ID = '123'; GH_TOKEN = $null; GITHUB_TOKEN = $null
        }
        $process = & $script:reportModule {
            param($Executable, $Runner, $Environment)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $Runner) `
                -EnvVars $Environment -IgnoreExitCode -Label 'Shared reporting action fixture'
        } (Get-Command pwsh -ErrorAction Stop).Source $runner $environment
        $process.ExitCode | Should -Be $ExpectedExitCode -Because $process.StdErr
        Get-Content -LiteralPath $summary -Raw | Should -Match 'terraform check status'
    }
}
