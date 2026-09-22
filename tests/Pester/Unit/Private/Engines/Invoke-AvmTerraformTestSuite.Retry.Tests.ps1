#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force

    function New-TestEvents {
        param([string] $Detail = 'SkuNotAvailable')
        $path = 'tests/integration/deploy.tftest.hcl'
        @(
            @{ type = 'test_abstract'; test_abstract = @{ $path = @('setup', 'deploy', 'update') } }
            @{ type = 'test_file'; test_file = @{ path = $path; progress = 'starting' } }
            @{ type = 'test_run'; test_run = @{ path = $path; run = 'setup'; progress = 'complete'; status = 'pass' } }
            @{ type = 'test_run'; test_run = @{ path = $path; run = 'deploy'; progress = 'complete'; status = 'error' } }
            @{
                type = 'diagnostic'; '@level' = 'error'; '@testfile' = $path; '@testrun' = 'deploy'
                diagnostic = @{
                    severity = 'error'; summary = 'Error creating/updating resource'; detail = $Detail
                    range = @{ filename = 'main.tf'; start = @{ line = 12; column = 3 } }
                }
            }
            @{ type = 'test_run'; test_run = @{ path = $path; run = 'update'; progress = 'complete'; status = 'skip' } }
            @{ type = 'test_file'; test_file = @{ path = $path; progress = 'teardown' } }
            @{ type = 'test_run'; test_run = @{ path = $path; run = 'setup'; progress = 'teardown' } }
            @{ type = 'test_file'; test_file = @{ path = $path; progress = 'complete'; status = 'error' } }
            @{ type = 'test_summary'; test_summary = @{ status = 'error'; passed = 1; failed = 0; errored = 1; skipped = 1 } }
        )
    }

    function New-TestProcessResult {
        param([object[]] $Events, [int] $ExitCode = 1, [string] $StdErr = '')
        [pscustomobject]@{
            ExitCode = $ExitCode
            StdOut = ($Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 10 -Compress }) -join "`n"
            StdErr = $StdErr
        }
    }

    function New-PassingTestResult {
        $events = @(New-TestEvents | Where-Object { $_.type -ne 'diagnostic' })
        foreach ($entry in $events) {
            if ($entry.type -eq 'test_run' -and $entry.test_run.progress -eq 'complete') { $entry.test_run.status = 'pass' }
            if ($entry.type -eq 'test_file' -and $entry.test_file.progress -eq 'complete') { $entry.test_file.status = 'pass' }
            if ($entry.type -eq 'test_summary') {
                $entry.test_summary = @{ status = 'pass'; passed = 3; failed = 0; errored = 0; skipped = 0 }
            }
        }
        New-TestProcessResult -Events $events -ExitCode 0
    }

    function Invoke-TestSuiteFixture {
        param(
            [object[]] $Results,
            [int] $MaxRetry = 2,
            [string] $Tier = 'integration',
            [string] $Configuration = 'run "deploy" {}',
            [switch] $NoInit,
            [switch] $Submodule
        )
        $state = @{
            Results = $Results; Index = 0
            Calls = [System.Collections.Generic.List[object]]::new()
            Logs = [System.Collections.Generic.List[string]]::new()
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            S = $state; Retry = $MaxRetry; T = $Tier; Config = $Configuration
            SkipInit = [bool]$NoInit; Child = [bool]$Submodule
        } {
            param($S, $Retry, $T, $Config, $SkipInit, $Child)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'terraform'; Version = '1.15.8'; Path = 'terraform-stub'; Source = 'cache' } }
            Mock Get-AvmTerraformTestTarget {
                param($Root)
                [pscustomobject]@{
                    Path = $Root; Rel = ''
                    Files = @([pscustomobject]@{ FullName = 'deploy.tftest.hcl' })
                }
                if ($Child) {
                    [pscustomobject]@{
                        Path = (Join-Path $Root 'modules' 'child'); Rel = 'modules/child'
                        Files = @([pscustomobject]@{ FullName = 'deploy.tftest.hcl' })
                    }
                }
            }
            Mock Test-Path { $false }
            Mock Get-Content { $Config }
            Mock Invoke-AvmTerraformSetupHook { $null }
            Mock ConvertFrom-AvmDotEnv {
                @{
                    TF_CLI_ARGS_test = '-filter=tests/integration/deploy.tftest.hcl'
                    ARM_SUBSCRIPTION_ID = 'test-subscription'
                    ARM_TENANT_ID = 'test-tenant'
                    CUSTOM = 'preserved'
                }
            }
            Mock Write-AvmLog { param($Message) $S.Logs.Add($Message) }
            Mock Invoke-AvmProcess {
                param($ArgumentList, $WorkingDirectory, $EnvVars, $OnStdOutLine)
                $S.Calls.Add([pscustomobject]@{ Arguments = $ArgumentList.Clone(); Directory = $WorkingDirectory; Environment = $EnvVars.Clone() })
                if ($ArgumentList[0] -eq 'init') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                $next = $S.Results[[math]::Min($S.Index, $S.Results.Count - 1)]
                $S.Index++
                if ($next -is [System.Exception]) { throw $next }
                foreach ($line in ($next.StdOut -split "`n")) { & $OnStdOutLine $line }
                return $next
            }
            $context = [pscustomobject]@{ Root = (Join-Path ([System.IO.Path]::GetTempPath()) 'avm-mocked-target'); Ecosystem = 'terraform' }
            $result = Invoke-AvmTerraformTestSuite -Context $context -Tier $T -MaxRetry $Retry -NoInit:$SkipInit
            [pscustomobject]@{ Result = $result; Calls = $S.Calls.ToArray(); Logs = $S.Logs.ToArray() }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform integration retry classification' {
    BeforeEach {
        $script:events = @(New-TestEvents)
        $script:originalPattern = $env:AVM_E2E_RETRY_PATTERN
        $env:AVM_E2E_RETRY_PATTERN = '.*'
    }

    AfterEach {
        $env:AVM_E2E_RETRY_PATTERN = $script:originalPattern
    }

    It 'accepts completed, cleaned-up <Detail>' -ForEach @(
        @{ Detail = 'SkuNotAvailable' }
        @{ Detail = 'Capacity Restrictions' }
        @{ Detail = 'size is currently not available in location test-region' }
        @{ Detail = 'sku_selector found no deployable VM size' }
        @{ Detail = 'AllocationFailed' }
        @{ Detail = 'Allocation Failed' }
        @{ Detail = 'results in exceeding approved quota' }
        @{ Detail = 'LocationNotAvailableForResourceGroup' }
        @{ Detail = 'currently experiencing high demand in test-region region' }
        @{ Detail = 'unexpected status 403 (403 Forbidden): RequestDisallowedByAzure: region not accepting new customers. See https://aka.ms/locationineligible' }
    ) {
        $process = New-TestProcessResult -Events (New-TestEvents -Detail $Detail)
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeTrue
        }
    }

    It 'rejects permanent <Summary> despite a broad E2E pattern' -ForEach @(
        @{ Summary = 'Test assertion failed'; Detail = 'SkuNotAvailable' }
        @{ Summary = 'Resource precondition failed'; Detail = 'Capacity Restrictions' }
        @{ Summary = 'Resource postcondition failed'; Detail = 'AllocationFailed' }
        @{ Summary = 'Invalid reference'; Detail = 'SkuNotAvailable' }
        @{ Summary = 'Invalid value for variable'; Detail = 'sku_selector found no deployable VM size' }
        @{ Summary = 'Missing required argument'; Detail = 'AllocationFailed' }
        @{ Summary = 'Provider produced inconsistent result after apply'; Detail = 'SkuNotAvailable' }
        @{ Summary = 'Error creating/updating resource'; Detail = '403 Forbidden: AuthorizationFailed' }
        @{ Summary = 'Error creating/updating resource'; Detail = '403 Forbidden: SkuNotAvailable' }
        @{ Summary = 'Error creating/updating resource'; Detail = '401 Unauthorized: SkuNotAvailable' }
        @{ Summary = 'Error creating/updating resource'; Detail = 'RequestDisallowedByAzure: denied by policy' }
        @{ Summary = 'Error creating/updating resource'; Detail = '403: request denied; https://aka.ms/locationineligible' }
        @{ Summary = 'Error creating/updating resource'; Detail = 'Unknown permanent service error' }
        @{ Summary = 'Error creating/updating resource'; Detail = 'OperationNotAllowed: cannot delete nested resources' }
    ) {
        $script:events[4].diagnostic.summary = $Summary
        $script:events[4].diagnostic.detail = $Detail
        $process = New-TestProcessResult -Events $script:events
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'rejects assertion status even when the diagnostic looks like capacity' {
        $script:events[3].test_run.status = 'fail'
        $script:events[-1].test_summary.failed = 1
        $script:events[-1].test_summary.errored = 0
        $process = New-TestProcessResult -Events $script:events
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'does not let one eligible diagnostic hide another error' {
        $unknown = @{
            type = 'diagnostic'; '@testfile' = 'tests/integration/deploy.tftest.hcl'; '@testrun' = 'deploy'
            diagnostic = @{ severity = 'error'; summary = 'Invalid reference'; detail = 'a configuration defect' }
        }
        $process = New-TestProcessResult -Events (@($script:events[0..4]) + $unknown + $script:events[5..9])
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'requires discovery, every run, teardown, file completion, and the final summary (missing <Index>)' -ForEach @(
        @{ Index = 0 }; @{ Index = 2 }; @{ Index = 3 }; @{ Index = 4 }; @{ Index = 6 }; @{ Index = 8 }; @{ Index = 9 }
    ) {
        $remaining = for ($i = 0; $i -lt $script:events.Count; $i++) {
            if ($i -ne $Index) { $script:events[$i] }
        }
        $process = New-TestProcessResult -Events $remaining
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'rejects malformed or unknown error output <Line>' -ForEach @(
        @{ Line = 'not JSON' }
        @{ Line = '{"type":' }
        @{ Line = 'null' }
        @{ Line = '[]' }
        @{ Line = '{"@level":"error","type":"unknown_error","@message":"unexpected problem"}' }
    ) {
        $process = New-TestProcessResult -Events $script:events
        $process.StdOut += "`n$Line"
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'rejects mismatched summary counts or unfinished selected files' -ForEach @(
        @{ Kind = 'count' }; @{ Kind = 'file' }; @{ Kind = 'diagnostic' }
    ) {
        switch ($Kind) {
            'count' { $script:events[-1].test_summary.errored = 2 }
            'file' { $script:events[0].test_abstract['tests/integration/other.tftest.hcl'] = @('other') }
            'diagnostic' {
                $script:events[2].test_run.status = 'error'
                $script:events[-1].test_summary.passed = 0
                $script:events[-1].test_summary.errored = 2
            }
        }
        $process = New-TestProcessResult -Events $script:events
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'rejects missing or malformed structured fields (<Index>)' -ForEach @(
        @{ Index = 0; Replacement = @{ type = 'test_abstract' } }
        @{ Index = 1; Replacement = @{ type = 'test_file' } }
        @{ Index = 2; Replacement = @{ type = 'test_run' } }
        @{ Index = 4; Replacement = @{ type = 'diagnostic' } }
        @{ Index = 4; Replacement = @{ type = 'diagnostic'; diagnostic = @{ severity = 'error'; detail = 'SkuNotAvailable' } } }
        @{ Index = 9; Replacement = @{ type = 'test_summary' } }
        @{ Index = 9; Replacement = @{ type = 'test_summary'; test_summary = @{ status = 'error'; errored = 1 } } }
    ) {
        $script:events[$Index] = $Replacement
        $process = New-TestProcessResult -Events $script:events
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'never retries cleanup or interrupt events (<Type>)' -ForEach @(
        @{ Type = 'test_cleanup' }; @{ Type = 'test_interrupt' }; @{ Type = 'log' }
    ) {
        $extra = @{ type = $Type; '@message' = 'Interrupt received; cleanup is required.' }
        if ($Type -eq 'test_cleanup') { $extra['@message'] = 'Terraform left some resources in state; clean up manually.' }
        $process = New-TestProcessResult -Events (@($script:events[0..7]) + $extra + $script:events[8..9])
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'does not retry an eligible-looking error or incomplete plan during cleanup' -ForEach @(
        @{ Severity = 'error'; Summary = 'Error deleting resource'; Detail = 'SkuNotAvailable' }
        @{ Severity = 'warning'; Summary = 'Incomplete destroy plan'; Detail = 'Some cleanup operations were deferred.' }
    ) {
        $extra = @{
            type = 'diagnostic'; '@testfile' = 'tests/integration/deploy.tftest.hcl'; '@testrun' = 'setup'
            diagnostic = @{ severity = $Severity; summary = $Summary; detail = $Detail }
        }
        $process = New-TestProcessResult -Events (@($script:events[0..7]) + $extra + $script:events[8..9])
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'allows Terraform in-run test_retry backoff messages' {
        $extra = @{ type = 'test_retry'; '@level' = 'error'; '@message' = 'Retrying request after a server error.' }
        $process = New-TestProcessResult -Events (@($script:events[0..3]) + $extra + $script:events[4..9])
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeTrue
        }
    }

    It 'rejects unexplained stderr and abnormal exit codes' -ForEach @(
        @{ ExitCode = 1; StdErr = 'unexpected permanent failure' }
        @{ ExitCode = 130; StdErr = '' }
        @{ ExitCode = 2; StdErr = '' }
    ) {
        $process = New-TestProcessResult -Events $script:events -ExitCode $ExitCode -StdErr $StdErr
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $process } {
            Test-AvmTerraformTestCompleted -Result $R -RetryableFailure | Should -BeFalse
        }
    }

    It 'requires completed successful cleanup before calling a retry recovered' {
        $pass = New-PassingTestResult
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $pass } {
            Test-AvmTerraformTestCompleted -Result $R | Should -BeTrue
        }
        $events = @($pass.StdOut -split "`n" | ConvertFrom-Json -AsHashtable)
        ($events | Where-Object { $_.type -eq 'test_file' -and $_.test_file.progress -eq 'complete' }).test_file.status = 'error'
        $invalid = New-TestProcessResult -Events $events -ExitCode 0
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $invalid } {
            Test-AvmTerraformTestCompleted -Result $R | Should -BeFalse
        }
    }
}

Describe 'Terraform integration retry execution' {
    BeforeEach {
        $script:failure = New-TestProcessResult -Events (New-TestEvents)
        $script:success = New-PassingTestResult
    }

    It 'retries the same target after cleanup and preserves final counts and earlier diagnostics' {
        $originalDirectory = (Get-Location).Path
        $originalFilter = $env:TF_CLI_ARGS_test
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, $script:success)
        $observed.Result.Status | Should -Be 'pass'
        $observed.Result.RunsTotal | Should -Be 3
        $observed.Result.RunsPassed | Should -Be 3
        $observed.Result.RunsFailed | Should -Be 0
        @($observed.Result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
        $diagnostic = @($observed.Result.Issues | Where-Object Line -eq 12)
        $diagnostic.Count | Should -Be 1
        $diagnostic[0].Severity | Should -Be 'warning'
        $diagnostic[0].Message | Should -Match 'Attempt 1:.*SkuNotAvailable'
        $observed.Logs -join "`n" | Should -Match 'teardown completed, retrying \(1 of 2\)'
        ($observed.Calls | ForEach-Object { $_.Arguments[0] }) -join ',' | Should -Be 'init,test,test'
        $tests = @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' })
        ($tests[0].Arguments -join '|') | Should -Be ($tests[1].Arguments -join '|')
        $tests[0].Directory | Should -Be $tests[1].Directory
        foreach ($call in $observed.Calls) {
            $call.Environment.TF_CLI_ARGS_test | Should -Be '-filter=tests/integration/deploy.tftest.hcl'
            $call.Environment.ARM_SUBSCRIPTION_ID | Should -Be 'test-subscription'
            $call.Environment.ARM_TENANT_ID | Should -Be 'test-tenant'
            $call.Environment.CUSTOM | Should -Be 'preserved'
        }
        (Get-Location).Path | Should -Be $originalDirectory
        $env:TF_CLI_ARGS_test | Should -Be $originalFilter
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformSetupHook -Times 1 -Exactly
            Should -Invoke ConvertFrom-AvmDotEnv -Times 1 -Exactly
        }
    }

    It 'uses exactly three default attempts and keeps exhaustion a failure' {
        $observed = Invoke-TestSuiteFixture -Results @($script:failure)
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 3
        @($observed.Result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 4
        @($observed.Result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 2
        $observed.Result.RunsFailed | Should -Be 1
        $observed.Result.Issues[-1].Message | Should -Match 'SkuNotAvailable'
    }

    It 'honors MaxRetry <Budget> and NoInit without changing test arguments' -ForEach @(
        @{ Budget = 0; Attempts = 1 }; @{ Budget = 1; Attempts = 2 }; @{ Budget = 10; Attempts = 11 }
    ) {
        $observed = Invoke-TestSuiteFixture -Results @($script:failure) -MaxRetry $Budget -NoInit
        $observed.Result.Status | Should -Be 'fail'
        $observed.Calls.Count | Should -Be $Attempts
        foreach ($call in $observed.Calls) { $call.Arguments[0] | Should -Be 'test' }
    }

    It 'leaves unit tests single-attempt even for a recognized capacity failure' {
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, $script:success) -Tier unit
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
    }

    It 'does not repeat successful earlier targets when a submodule needs a retry' {
        $observed = Invoke-TestSuiteFixture -Results @($script:success, $script:failure, $script:success) -Submodule
        $observed.Result.Status | Should -Be 'pass'
        $tests = @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' })
        $tests.Count | Should -Be 3
        $tests[1].Directory | Should -Be $tests[2].Directory
        $tests[1].Directory | Should -Not -Be $tests[0].Directory
        $observed.Result.RunsTotal | Should -Be 6
        @($observed.Result.Issues | Where-Object File -eq 'modules/child/main.tf').Count | Should -Be 1
    }

    It 'runs authored cleanup/state controls once but never automatically replays them (<Config>)' -ForEach @(
        @{ Config = 'run "deploy" { skip_cleanup = true }' }
        @{ Config = 'state_store "local" {}' }
        @{ Config = 'run "deploy" { backend = "test-state" }' }
    ) {
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, $script:success) -Configuration $Config
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
        $observed.Logs -join "`n" | Should -Match 'retries disabled.*cleanup or persistent-state'
    }

    It 'reports failed cleanup explicitly instead of retrying or losing its message' {
        $events = @(New-TestEvents)
        $events += @{ type = 'test_cleanup'; '@testfile' = 'tests/integration/deploy.tftest.hcl'; '@message' = 'Terraform left resources; clean up manually.' }
        $observed = Invoke-TestSuiteFixture -Results @((New-TestProcessResult -Events $events), $script:success)
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
        ($observed.Result.Issues | Where-Object Code -eq 'test_cleanup').Message | Should -Be 'Terraform left resources; clean up manually.'
    }

    It 'does not turn an empty or skipped retry into success (<Kind>)' -ForEach @(
        @{ Kind = 'empty' }; @{ Kind = 'skipped' }
    ) {
        $events = @()
        if ($Kind -eq 'skipped') {
            $events = @(
                @{ type = 'test_run'; test_run = @{ path = 'tests/integration/deploy.tftest.hcl'; run = 'deploy'; progress = 'complete'; status = 'skip' } }
                @{ type = 'test_summary'; test_summary = @{ status = 'skip'; passed = 0; failed = 0; errored = 0; skipped = 1 } }
            )
        }
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, (New-TestProcessResult -Events $events -ExitCode 0))
        $observed.Result.Status | Should -Be 'fail'
        $observed.Result.Issues[-1].Message | Should -Match 'skipped, empty, or incomplete retries cannot recover'
    }

    It 'rejects a truncated successful retry and preserves earlier error diagnostics' {
        $script:success.StdOut = ($script:success.StdOut -split "`n" | Select-Object -SkipLast 1) -join "`n"
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, $script:success)
        $observed.Result.Status | Should -Be 'fail'
        $observed.Result.Issues[-1].Message | Should -Match 'incomplete retries cannot recover'
        @($observed.Result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 2
    }

    It 'does not report an empty first integration attempt as a pass' {
        $observed = Invoke-TestSuiteFixture -Results @((New-TestProcessResult -Events @() -ExitCode 0))
        $observed.Result.Status | Should -Be 'fail'
        $observed.Result.RunsTotal | Should -Be 0
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
    }

    It 'keeps permanent errors and assertions single-attempt in the runner (<Detail>)' -ForEach @(
        @{ Summary = 'Error creating/updating resource'; Detail = '403 Forbidden: AuthorizationFailed' }
        @{ Summary = 'Error creating/updating resource'; Detail = 'Unknown permanent error' }
        @{ Summary = 'Test assertion failed'; Detail = 'SkuNotAvailable' }
    ) {
        $events = @(New-TestEvents -Detail $Detail)
        $events[4].diagnostic.summary = $Summary
        $observed = Invoke-TestSuiteFixture -Results @((New-TestProcessResult -Events $events), $script:success)
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
        $observed.Result.Issues[-1].Message | Should -Match ([regex]::Escape($Detail))
    }

    It 'preserves unstructured and unknown structured errors without replaying' -ForEach @(
        @{ Text = 'unknown permanent stdout failure' }
        @{ Text = '{"@level":"error","type":"unknown_error","@message":"unknown permanent stdout failure"}' }
    ) {
        $script:failure.StdOut += "`n$Text"
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, $script:success)
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
        ($observed.Result.Issues.Message -join "`n") | Should -Match 'unknown permanent stdout failure'
    }

    It 'propagates an abnormal process exit with its original diagnostic' {
        $script:failure.ExitCode = 130
        $script:failure.StdErr = 'terraform was interrupted'
        { Invoke-TestSuiteFixture -Results @($script:failure, $script:success) } |
            Should -Throw -ExpectedMessage '*code 130*terraform was interrupted*'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }

    It 'preserves unexpected stderr even when a structured capacity diagnostic is present' {
        $script:failure.StdErr = 'unknown permanent error from the test process'
        $observed = Invoke-TestSuiteFixture -Results @($script:failure, $script:success)
        $observed.Result.Status | Should -Be 'fail'
        @($observed.Calls | Where-Object { $_.Arguments[0] -eq 'test' }).Count | Should -Be 1
        $observed.Result.Issues[-1].Message | Should -Match 'unknown permanent error from the test process'
    }

    It 'propagates cancellation and timeout exceptions without consuming another attempt' -ForEach @(
        @{ Exception = [System.OperationCanceledException]::new('cancelled') }
        @{ Exception = [System.TimeoutException]::new('timed out') }
    ) {
        { Invoke-TestSuiteFixture -Results @($Exception, $script:success) } | Should -Throw -ExpectedMessage "*$($Exception.Message)*"
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'test' }
        }
    }
}
