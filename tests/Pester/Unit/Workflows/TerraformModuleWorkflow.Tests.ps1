#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'terraform-module reusable workflow' {
    BeforeAll {
        $script:workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $script:workflowPath -Raw

        $jobMatch = [regex]::Match($script:workflow, '(?ms)^  e2e-test:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        if (-not $jobMatch.Success) { throw 'Could not isolate the e2e-test job block.' }
        $script:e2eJob = $jobMatch.Value
        $discoveryMatch = [regex]::Match($script:workflow, '(?ms)^  discover-examples:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        if (-not $discoveryMatch.Success) { throw 'Could not isolate the discover-examples job block.' }
        $script:discoveryJob = $discoveryMatch.Value
    }

    It 'uses the shared retrying installer and version input in <Job>' -ForEach @(
        @{ Job = 'unit-test'; Run = '&install-avm-authoring |' }
        @{ Job = 'pr-check-fork'; Run = '*install-avm-authoring' }
        @{ Job = 'pr-check'; Run = '*install-avm-authoring' }
        @{ Job = 'integration-test'; Run = '*install-avm-authoring' }
        @{ Job = 'discover-examples'; Run = '*install-avm-authoring' }
        @{ Job = 'e2e-test'; Run = '*install-avm-authoring' }
    ) {
        $jobPattern = '(?ms)^  ' + [regex]::Escape($Job) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)'
        $jobBlock = [regex]::Match($script:workflow, $jobPattern).Value
        $jobBlock | Should -Match (
            '(?m)^      - name: Install Avm\.Authoring\r?\n' +
            '        shell: pwsh\r?\n' +
            '        env:\r?\n' +
            '          AVM_AUTHORING_VERSION: \$\{\{ inputs\.avm-authoring-version \}\}\r?\n' +
            '        run: ' + [regex]::Escape($Run) + '\r?$'
        )
    }

    It 'passes the non-secret subscription ID as a job output without masking it' {
        $script:workflow | Should -Match '"subscriptionId=\$\(\$chosen\.id\)"'
        $script:workflow | Should -Not -Match '::add-mask::'
    }

    It 'publishes the shuffled General subscription list for the e2e fan-out' {
        $script:workflow | Should -Match 'subscriptionIds:\s*\$\{\{ steps\.pick\.outputs\.subscriptionIds \}\}'
        $script:workflow | Should -Match '"subscriptionIds=\$ordered"'
    }

    It 'discovers e2e examples with the machine-readable list surface' {
        $script:workflow | Should -Match 'avm test e2e --list'
        $script:workflow | Should -Match 'examples:\s*\$\{\{ steps\.list\.outputs\.examples \}\}'
        $script:workflow | Should -Match 'hasExamples:\s*\$\{\{ steps\.list\.outputs\.hasExamples \}\}'
    }

    It 'fans e2e out across a per-example matrix that does not fail fast' {
        $script:workflow | Should -Match 'fail-fast:\s*false'
        $script:workflow | Should -Match 'example:\s*\$\{\{ fromJson\(needs\.discover-examples\.outputs\.examples\) \}\}'
        $script:workflow | Should -Match 'name:\s*End-to-end tests \(\$\{\{ matrix\.example \}\}\)'
        $script:workflow | Should -Match 'avm test e2e --example'
    }

    It 'skips the e2e matrix when no runnable examples were discovered' {
        $script:workflow | Should -Match "needs\.discover-examples\.outputs\.hasExamples == 'true'"
    }

    It 'keeps e2e execution on a static environment separate from discovery approval' {
        $script:e2eJob | Should -Match '(?m)^    environment: examples-test-execution\r?$'
        $script:workflow | Should -Not -Match 'environment:\s*.*\$\{\{\s*matrix\.'
    }

    It 'keeps the whole e2e matrix dependent on successful protected discovery' {
        $script:e2eJob | Should -Match 'needs:\s*\[subscriptions, discover-examples\]'
        $script:e2eJob | Should -Not -Match 'always\(\)|cancelled\(\)|failure\(\)|continue-on-error:'
        $script:discoveryJob | Should -Not -Match 'continue-on-error:'
    }

    It 'declares the e2e approval gate only on non-matrix discovery without OIDC write permission' {
        ([regex]::Matches($script:workflow, '(?m)^\s*environment:\s*examples-test\s*$')).Count | Should -Be 1
        $script:discoveryJob | Should -Match '(?m)^    environment: examples-test\r?$'
        $script:discoveryJob | Should -Not -Match 'strategy:|id-token:'
    }

    It 'round-robins the subscription across matrix legs using strategy.job-index' {
        $script:workflow | Should -Match 'JOB_INDEX:\s*\$\{\{ strategy\.job-index \}\}'
        $script:workflow | Should -Match '\$subs\[\$index % \$subs\.Count\]'
    }

    It 'keeps the single-subscription fallback path for the matrix legs' {
        $script:workflow | Should -Match 'FALLBACK_SUBSCRIPTION_ID:\s*\$\{\{ needs\.subscriptions\.outputs\.subscriptionId \}\}'
    }

    It 'no longer lists per-example e2e targeting as a divergence' {
        $script:workflow | Should -Not -Match 'has no per-example targeting'
    }
}

Describe 'Terraform General subscription selection' {
    BeforeAll {
        $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
        $workflow = Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'terraform-module.yml') -Raw
        $script:reservationScripts = @{}
        foreach ($job in @('subscriptions', 'pr-check', 'integration-test', 'e2e-test')) {
            $block = [regex]::Match($workflow, '(?ms)^  ' + [regex]::Escape($job) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)').Value
            $step = if ($job -ceq 'subscriptions') { 'Shuffle and select a test subscription' } else { 'Prepare test environment' }
            $run = [regex]::Match($block, '(?ms)^      - name: ' + [regex]::Escape($step) +
                '\r?\n.*?^        run: \|\r?\n(?<body>(?: {10}[^\r\n]*\r?\n|\r?\n)*)')
            $run.Success | Should -BeTrue
            $script:reservationScripts[$job] = [scriptblock]::Create(($run.Groups['body'].Value -replace '(?m)^ {10}', ''))
        }
    }

    BeforeEach {
        $script:previousEnvironment = @{}
        $script:bundle = New-AvmTestBamiSettings
        foreach ($name in @($script:bundle.Keys) + @(
            'TEST_SUBSCRIPTION_IDS', 'FALLBACK_SUBSCRIPTION_ID_SECRET', 'FALLBACK_SUBSCRIPTION_ID_VAR',
            'GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_WORKSPACE', 'SUBSCRIPTION_IDS', 'SELECTED_SUBSCRIPTION_ID',
            'SECRETS_CONTEXT', 'VARS_CONTEXT', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_URL'
        )) {
            $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
        $env:GITHUB_OUTPUT = 'fixture-output'
        $env:GITHUB_ENV = 'fixture-environment'
        $env:GITHUB_WORKSPACE = $script:root
        $script:written = @{
            'fixture-output' = [System.Collections.Generic.List[string]]::new()
            'fixture-environment' = [System.Collections.Generic.List[string]]::new()
        }
        Mock Out-File {
            param($InputObject, $FilePath)
            $script:written[$FilePath].Add([string]$InputObject)
        } -RemoveParameterType Encoding
        Mock Write-Host {}
        $script:reserved = $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0]
        $script:general = $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[1]
        $script:untagged = $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[2]
        $script:reserved.tag = 'Azure Local'
        $script:general.tag = 'General'
    }

    AfterEach {
        foreach ($name in $script:previousEnvironment.Keys) {
            $value = $script:previousEnvironment[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
        }
    }

    It 'filters reserved subscriptions before shuffling, choosing a default, and publishing the matrix pool' {
        $env:TEST_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:reserved, $script:general, $script:untagged) -Compress
        & $script:reservationScripts.subscriptions
        $lines = $script:written['fixture-output']
        $selected = @($lines | Where-Object { $_.StartsWith('subscriptionId=') })[0].Substring('subscriptionId='.Length)
        $json = @($lines | Where-Object { $_.StartsWith('subscriptionIds=') })[0].Substring('subscriptionIds='.Length)
        $pool = ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate
        $pool | Should -HaveCount 2
        $pool.id | Should -Not -Contain $script:reserved.id
        $selected | Should -BeIn @($script:general.id, $script:untagged.id)
        @($pool.id | Sort-Object) | Should -Be @(@($script:general.id, $script:untagged.id) | Sort-Object)
        foreach ($entry in $pool) { $entry.Count | Should -Be 2 }
    }

    It 'keeps an entirely untagged historical pool usable' {
        $script:general.Remove('tag')
        $env:TEST_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:general, $script:untagged) -Compress
        & $script:reservationScripts.subscriptions
        $json = @($script:written['fixture-output'] | Where-Object { $_.StartsWith('subscriptionIds=') })[0].Substring('subscriptionIds='.Length)
        @((ConvertFrom-Json -InputObject $json).id | Sort-Object) |
            Should -Be @(@($script:general.id, $script:untagged.id) | Sort-Object)
    }

    It 'does not use a legacy fallback for a configured pool without General subscriptions: <Tag>' -ForEach @(
        @{ Tag = 'Azure Local' }
        @{ Tag = 'Another reservation' }
        @{ Tag = 'general' }
    ) {
        $script:reserved.tag = $Tag
        $env:TEST_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:reserved) -Compress
        $env:FALLBACK_SUBSCRIPTION_ID_SECRET = $script:reserved.id
        $env:FALLBACK_SUBSCRIPTION_ID_VAR = $script:general.id
        { & $script:reservationScripts.subscriptions } | Should -Throw '*at least one General*falls back*'
        Should -Invoke Out-File -Exactly 0
    }

    It 'rejects an explicitly malformed tag before producing any selection: <Case>' -ForEach @(
        @{ Case = 'null'; Value = $null }
        @{ Case = 'empty'; Value = '' }
        @{ Case = 'whitespace'; Value = ' ' }
        @{ Case = 'leading whitespace'; Value = ' General' }
        @{ Case = 'trailing whitespace'; Value = 'General ' }
        @{ Case = 'control character'; Value = "Azure`nLocal" }
        @{ Case = 'underscore'; Value = 'Azure_Local' }
        @{ Case = 'repeated separators'; Value = 'Azure--Local' }
        @{ Case = 'too long'; Value = ('A' * 65) }
        @{ Case = 'boolean'; Value = $true }
        @{ Case = 'number'; Value = 1 }
        @{ Case = 'array'; Value = @('General') }
        @{ Case = 'object'; Value = @{ name = 'General' } }
    ) {
        $script:reserved.tag = $Value
        $env:TEST_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:reserved, $script:general) -Depth 5 -Compress
        { & $script:reservationScripts.subscriptions } | Should -Throw '*subscription tag must be*'
        Should -Invoke Out-File -Exactly 0
    }

    It 'rejects ambiguous properties and malformed or empty pools: <Case>' -ForEach @(
        @{ Case = 'duplicate tag'; Json = '[{"id":"10000000-0000-4000-8000-000000000001","name":"test","tag":"Azure Local","tag":"General"}]' }
        @{ Case = 'case-colliding tags'; Json = '[{"id":"10000000-0000-4000-8000-000000000001","name":"test","tag":"Azure Local","Tag":"General"}]' }
        @{ Case = 'wrongly cased tag'; Json = '[{"id":"10000000-0000-4000-8000-000000000001","name":"test","Tag":"Azure Local"}]' }
        @{ Case = 'object instead of array'; Json = '{"id":"10000000-0000-4000-8000-000000000001","name":"test"}' }
        @{ Case = 'empty array'; Json = '[]' }
        @{ Case = 'non-object entry'; Json = '[null]' }
        @{ Case = 'whitespace JSON'; Json = ' ' }
        @{ Case = 'unknown property'; Json = '[{"id":"10000000-0000-4000-8000-000000000001","name":"test","extra":"value"}]' }
        @{ Case = 'duplicate across tags'; Json = '[{"id":"ABCDEF01-ABCD-4ABC-8ABC-ABCDEF012345","name":"reserved","tag":"Azure Local"},{"id":"abcdef01-abcd-4abc-8abc-abcdef012345","name":"general"}]' }
    ) {
        $env:TEST_SUBSCRIPTION_IDS = $Json
        $env:FALLBACK_SUBSCRIPTION_ID_SECRET = $script:reserved.id
        { & $script:reservationScripts.subscriptions } | Should -Throw
        Should -Invoke Out-File -Exactly 0
    }

    It 'preserves secret-before-variable fallback only when no pool is configured' -ForEach @($false, $true) {
        $env:FALLBACK_SUBSCRIPTION_ID_VAR = $script:untagged.id
        if ($_) { $env:FALLBACK_SUBSCRIPTION_ID_SECRET = $script:general.id }
        & $script:reservationScripts.subscriptions
        $expected = if ($_) { $script:general.id } else { $script:untagged.id }
        $script:written['fixture-output'] | Should -Contain "subscriptionId=$expected"
    }

    It 'rejects an override outside the General pool before <Job> can publish its environment' -ForEach @(
        @{ Job = 'pr-check' }
        @{ Job = 'integration-test' }
        @{ Job = 'e2e-test' }
    ) {
        $env:SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:general, $script:untagged) -Compress
        $env:SELECTED_SUBSCRIPTION_ID = $script:general.id
        $env:SECRETS_CONTEXT = ConvertTo-Json -InputObject @{ ARM_SUBSCRIPTION_ID_OVERRIDE = $script:reserved.id } -Compress
        $env:VARS_CONTEXT = '{}'
        { & $script:reservationScripts[$Job] } | Should -Throw '*OVERRIDE must belong*General*'
        Should -Invoke Out-File -Exactly 0
    }

    It 'keeps General overrides and replaces an unfiltered ambient pool for <Job>' -ForEach @(
        @{ Job = 'pr-check' }
        @{ Job = 'integration-test' }
        @{ Job = 'e2e-test' }
    ) {
        $env:SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:general, $script:untagged) -Compress
        $env:SELECTED_SUBSCRIPTION_ID = $script:general.id
        $env:VARS_CONTEXT = ConvertTo-Json -InputObject @{ ARM_SUBSCRIPTION_ID = $script:reserved.id } -Compress
        $env:SECRETS_CONTEXT = ConvertTo-Json -InputObject @{
            ARM_SUBSCRIPTION_ID_OVERRIDE = $script:untagged.id
            TEST_SUBSCRIPTION_IDS = (ConvertTo-Json -InputObject @($script:reserved, $script:general, $script:untagged) -Compress)
        } -Compress
        & $script:reservationScripts[$Job]
        $writes = $script:written['fixture-environment']
        $writes | Should -Contain "ARM_SUBSCRIPTION_ID=$($script:untagged.id)"
        $poolWrite = @($writes | Where-Object { $_.StartsWith('TEST_SUBSCRIPTION_IDS<<') })
        $poolWrite | Should -HaveCount 1
        $poolWrite[0] | Should -Match ([regex]::Escape($env:SUBSCRIPTION_IDS))
        $poolWrite[0] | Should -Not -Match ([regex]::Escape($script:reserved.id))
    }

    It 'rejects a missing or inconsistent selected pool before <Job> can fall back to ambient ARM settings' -ForEach @(
        @{ Job = 'pr-check' }
        @{ Job = 'integration-test' }
        @{ Job = 'e2e-test' }
    ) {
        $env:SUBSCRIPTION_IDS = '[]'
        $env:SELECTED_SUBSCRIPTION_ID = $script:reserved.id
        $env:SECRETS_CONTEXT = ConvertTo-Json -InputObject @{ ARM_SUBSCRIPTION_ID = $script:reserved.id } -Compress
        $env:VARS_CONTEXT = '{}'
        { & $script:reservationScripts[$Job] } | Should -Throw '*published General test pool*'
        Should -Invoke Out-File -Exactly 0
    }

    It 'replaces a stale ambient default with the selected General subscription in <Job>' -ForEach @(
        @{ Job = 'pr-check' }
        @{ Job = 'integration-test' }
        @{ Job = 'e2e-test' }
    ) {
        $env:SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @($script:general, $script:untagged) -Compress
        $env:SELECTED_SUBSCRIPTION_ID = $script:general.id
        $env:SECRETS_CONTEXT = ConvertTo-Json -InputObject @{ ARM_SUBSCRIPTION_ID = $script:reserved.id } -Compress
        $env:VARS_CONTEXT = '{}'
        & $script:reservationScripts[$Job]
        $script:written['fixture-environment'] | Should -Contain "ARM_SUBSCRIPTION_ID=$($script:general.id)"
        $script:written['fixture-environment'] | Should -Not -Contain "ARM_SUBSCRIPTION_ID=$($script:reserved.id)"
    }
}

Describe 'terraform-module automatic checks and fork isolation' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $workflowPath = Join-Path $root '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $workflowPath -Raw
        $module = Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
        $null = & $module { Import-AvmPowerShellModule -Name powershell-yaml -Global }
        $script:definition = ConvertFrom-Yaml -Yaml $script:workflow
        $script:jobs = @{}
        foreach ($name in @('subscriptions', 'unit-test', 'pr-check', 'pr-check-fork', 'integration-test', 'discover-examples', 'e2e-test')) {
            $pattern = '(?ms)^  ' + [regex]::Escape($name) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)'
            $block = [regex]::Match($script:workflow, $pattern)
            if (-not $block.Success) { throw "Could not isolate the $name job block." }
            $script:jobs[$name] = $block.Value
        }
        $unitRun = [regex]::Match(
            $script:jobs['unit-test'],
            '(?m)^      - name: Run unit tests\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<code>(?:^          .*\r?\n|^\r?\n)*)')
        if (-not $unitRun.Success -or [string]::IsNullOrWhiteSpace($unitRun.Groups['code'].Value)) {
            throw 'Could not isolate the unit-test script.'
        }
        $script:unitTestScript = [scriptblock]::Create(($unitRun.Groups['code'].Value -replace '(?m)^          ', ''))
        $run = [regex]::Match(
            $script:jobs['pr-check-fork'],
            '(?m)^      - name: Run PR check without policy\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<code>(?:^          .*\r?\n|^\r?\n)*)')
        if (-not $run.Success -or [string]::IsNullOrWhiteSpace($run.Groups['code'].Value)) {
            throw 'Could not isolate the fork pr-check script.'
        }
        $script:forkCheckScript = [scriptblock]::Create(($run.Groups['code'].Value -replace '(?m)^          ', ''))
    }

    It 'runs <Job> independently with read-only permissions and no protected environment' -ForEach @(
        @{ Job = 'unit-test' }
        @{ Job = 'pr-check-fork' }
    ) {
        $block = $script:jobs[$Job]
        $block | Should -Match '(?m)^    runs-on: ubuntu-latest\r?$'
        $block | Should -Match '(?m)^    permissions:\r?\n      contents: read\r?\n    env:'
        $block | Should -Not -Match 'environment:|needs:|id-token:|azure/login@|SELECTED_SUBSCRIPTION|register-features'
        $block | Should -Not -Match '\$\{\{\s*(?:secrets|vars)\.'
        @($script:definition.jobs[$Job].permissions.Keys) | Should -Be @('contents')
        $script:definition.jobs[$Job].permissions.contents | Should -BeExactly 'read'
    }

    It 'overrides inherited credential contexts and disables OIDC in <Job>' -ForEach @(
        @{ Job = 'unit-test' }
        @{ Job = 'pr-check-fork' }
    ) {
        $environment = $script:definition.jobs[$Job].env
        @($environment.Keys | Sort-Object) | Should -Be @('ARM_USE_OIDC', 'SECRETS_CONTEXT', 'VARS_CONTEXT')
        $environment.SECRETS_CONTEXT | Should -BeExactly '{}'
        $environment.VARS_CONTEXT | Should -BeExactly '{}'
        $environment.ARM_USE_OIDC | Should -BeExactly 'false'
    }

    It 'runs exactly one unit-test job on every invocation without branch, draft, or event gates' {
        @($script:definition.jobs.Keys | Where-Object { $_ -like 'unit-test*' }) | Should -Be @('unit-test')
        $job = $script:definition.jobs['unit-test']
        foreach ($key in @('if', 'needs', 'environment', 'continue-on-error')) {
            $job.Contains($key) | Should -BeFalse
        }
        $job.steps | Should -HaveCount 4
        foreach ($step in $job.steps) {
            $step.Contains('if') | Should -BeFalse
            $step.Contains('continue-on-error') | Should -BeFalse
        }
        $script:jobs['unit-test'] | Should -Not -Match 'Prepare test environment|ConvertFrom-Context|github\.event'
        $script:jobs['unit-test'] | Should -Match '(?m)^\s+avm test unit\r?$'
        $script:jobs['unit-test'] | Should -Match '(?m)^          persist-credentials: false\r?$'
    }

    It 'isolates the unit test telemetry default and restores <Scenario>' -ForEach @(
        @{ Scenario = 'an inherited opt-out after success'; InitialTelemetry = 'false'; Fails = $false }
        @{ Scenario = 'an absent value after success'; InitialTelemetry = $null; Fails = $false }
        @{ Scenario = 'an inherited opt-out after failure'; InitialTelemetry = 'false'; Fails = $true }
    ) {
        param($InitialTelemetry, [bool] $Fails)
        $previousTelemetry = [Environment]::GetEnvironmentVariable('TF_VAR_enable_telemetry', 'Process')
        try {
            $initialValue = if ($null -eq $InitialTelemetry) { [NullString]::Value } else { $InitialTelemetry }
            [Environment]::SetEnvironmentVariable('TF_VAR_enable_telemetry', $initialValue, 'Process')
            $script:unitTestTelemetry = $null
            $result = & {
                function Import-Module {
                    param([string] $Name)
                    $Name | Should -BeExactly 'Avm.Authoring'
                }
                function Invoke-UnitTestCommand {
                    param([string] $Verb, [string] $Tier)
                    $script:unitTestTelemetry = [Environment]::GetEnvironmentVariable('TF_VAR_enable_telemetry', 'Process')
                    if ($Fails) {
                        throw 'Expected unit test failure.'
                    }
                    [pscustomobject]@{
                        Verb = $Verb
                        Tier = $Tier
                    }
                }
                Set-Alias -Name avm -Value Invoke-UnitTestCommand -Scope Local

                if ($Fails) {
                    { & $script:unitTestScript } | Should -Throw '*Expected unit test failure.*'
                }
                else {
                    & $script:unitTestScript
                }
            }

            if (-not $Fails) {
                $result.Verb | Should -BeExactly 'test'
                $result.Tier | Should -BeExactly 'unit'
            }
            $script:unitTestTelemetry | Should -BeNullOrEmpty
            $restoredTelemetry = [Environment]::GetEnvironmentVariable('TF_VAR_enable_telemetry', 'Process')
            if ($null -eq $InitialTelemetry) {
                $restoredTelemetry | Should -BeNullOrEmpty
            }
            else {
                $restoredTelemetry | Should -BeExactly $InitialTelemetry
            }
            $script:definition.env.TF_VAR_enable_telemetry | Should -BeExactly 'false'
        }
        finally {
            $restore = if ($null -eq $previousTelemetry) { [NullString]::Value } else { $previousTelemetry }
            [Environment]::SetEnvironmentVariable('TF_VAR_enable_telemetry', $restore, 'Process')
        }
    }

    It 'selects the appropriate PR check using only the fork status' {
        $script:definition.jobs['pr-check-fork']['if'] |
            Should -BeExactly 'github.event.pull_request.head.repo.fork == true'
        $script:definition.jobs['pr-check']['if'] |
            Should -BeExactly 'github.event.pull_request.head.repo.fork == false'
        $script:definition.jobs.subscriptions['if'] |
            Should -BeExactly 'github.event.pull_request.head.repo.fork == false'
        $script:definition.jobs['pr-check'].needs | Should -BeExactly 'subscriptions'
        $script:definition.jobs.subscriptions.environment | Should -BeExactly 'no-approval'
        $script:definition.jobs.subscriptions.Contains('needs') | Should -BeFalse
        foreach ($job in @('pr-check', 'pr-check-fork')) {
            foreach ($step in $script:definition.jobs[$job].steps) {
                $step.Contains('if') | Should -BeFalse
                $step.Contains('continue-on-error') | Should -BeFalse
            }
        }
    }

    It 'uses the existing cache setup and non-persistent checkout for fork pr-check' {
        $script:jobs['unit-test'] | Should -Match '(?m)^        run: &configure-avm-tool-cache \|\r?$'
        $script:jobs['pr-check-fork'] | Should -Match '(?m)^        run: \*configure-avm-tool-cache\r?$'
        $script:jobs['pr-check-fork'] | Should -Match '(?m)^          persist-credentials: false\r?$'
        $script:jobs['pr-check-fork'] | Should -Not -Match 'continue-on-error:|Prepare test environment'
    }

    It 'rejects an older module before invoking any checks' {
        & {
            function Import-Module {
                param([string] $Name)
                $Name | Should -Be 'Avm.Authoring'
            }
            function Invoke-AvmPrCheck { param([string] $Path) }
            function Invoke-ForkCheckTestCommand { throw 'Checks must not execute with an older module.' }
            Set-Alias -Name avm -Value Invoke-ForkCheckTestCommand -Scope Local

            { & $script:forkCheckScript } | Should -Throw '*Fork checks require an Avm.Authoring release with -ExcludeSteps*'
        }
    }

    It 'runs the composite command excluding only policy with a compatible module and <AliasState>' -ForEach @(
        @{ AliasState = 'no inherited alias'; InheritedAlias = $false }
        @{ AliasState = 'an inherited alias'; InheritedAlias = $true }
    ) {
        param($InheritedAlias)
        $result = & {
            if ($InheritedAlias) {
                function Invoke-UnexpectedForkCheck { throw 'The inherited avm alias must not execute.' }
                Set-Alias -Name avm -Value Invoke-UnexpectedForkCheck -Scope Local
            }
            & {
                function Import-Module {
                    param([string] $Name)
                    $Name | Should -Be 'Avm.Authoring'
                }
                function Invoke-AvmPrCheck { param([string[]] $ExcludeSteps) }
                function Invoke-ForkCheckTestCommand {
                    param([string] $Verb, [string[]] $ExcludeSteps)
                    [pscustomobject]@{ Verb = $Verb; Exclusions = $ExcludeSteps }
                }
                Set-Alias -Name avm -Value Invoke-ForkCheckTestCommand -Scope Local

                & $script:forkCheckScript
            }
        }
        $result.Verb | Should -Be 'pr-check'
        $result.Exclusions | Should -Be @('check policy')
    }

    It 'retains the non-fork gate for <Job>' -ForEach @(
        @{ Job = 'subscriptions' }
        @{ Job = 'pr-check' }
        @{ Job = 'integration-test' }
        @{ Job = 'discover-examples' }
        @{ Job = 'e2e-test' }
    ) {
        $script:jobs[$Job] | Should -Match 'github\.event\.pull_request\.head\.repo\.fork == false'
    }

    It 'preserves normal-branch pr-check credentials, OIDC environment, and the full command' {
        $script:jobs['pr-check'] | Should -Match '(?m)^    environment: pr-check\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^    needs: subscriptions\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^      id-token: write\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^          avm pr-check\r?$'
        $script:jobs['pr-check'] | Should -Not -Match 'ExcludeSteps|unprivileged-environment'
        $script:jobs['pr-check'] | Should -Match 'ConvertFrom-Context \$env:SECRETS_CONTEXT'
        $script:jobs['pr-check'] | Should -Match 'ConvertFrom-Context \$env:VARS_CONTEXT'
    }
}

Describe 'terraform-module required Azure feature registration' {
    BeforeAll {
        $workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $workflowPath -Raw
        $script:jobs = @{}
        foreach ($name in @('subscriptions', 'unit-test', 'pr-check', 'integration-test', 'e2e-test')) {
            $pattern = '(?ms)^  ' + [regex]::Escape($name) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)'
            $block = [regex]::Match($script:workflow, $pattern)
            if (-not $block.Success) {
                throw "Could not isolate the $name job block."
            }
            $script:jobs[$name] = $block.Value
        }
    }

    It 'never signs in to Azure or registers features in selector, unit, or pr-check jobs' -ForEach @(
        @{ Job = 'subscriptions' }
        @{ Job = 'unit-test' }
        @{ Job = 'pr-check' }
    ) {
        $script:jobs[$Job] | Should -Not -Match 'azure/login@|register-features|Register required features'
    }

    It 'adds pinned Azure login only to the two protected deployment test jobs' {
        ([regex]::Matches($script:workflow, 'uses: azure/login@7ddb5af1ef8758cf1353cf3b42f940aee27ba21c')).Count |
            Should -Be 2
        $script:jobs['integration-test'] | Should -Match '(?m)^    environment: integration-test\r?$'
        $script:jobs['e2e-test'] | Should -Match '(?m)^    environment: examples-test-execution\r?$'
        $script:workflow | Should -Not -Match '(?i)feature unregister|provider unregister'
    }

    It 'uses the effective test identity and the correct selected subscription in <Job>' -ForEach @(
        @{ Job = 'integration-test'; Selection = 'needs.subscriptions.outputs.subscriptionId' }
        @{ Job = 'e2e-test'; Selection = 'steps.leg.outputs.subscriptionId' }
    ) {
        $block = $script:jobs[$Job]
        $block | Should -Match 'client-id: \$\{\{ env\.ARM_CLIENT_ID \}\}'
        $block | Should -Match 'tenant-id: \$\{\{ env\.ARM_TENANT_ID \}\}'
        $block | Should -Match ('subscription-id: \$\{\{ ' + [regex]::Escape($Selection) + ' \}\}')
        $block | Should -Match ('SELECTED_SUBSCRIPTION_ID: \$\{\{ ' + [regex]::Escape($Selection) + ' \}\}')
        ([regex]::Matches($block, "if: steps.required-features.outputs.required == 'true'")).Count |
            Should -Be 2
    }

    It 'checks manifest shape and effective subscription offline before allowing Azure login' {
        $block = $script:jobs['integration-test']
        $block | Should -Match "Test-Path -LiteralPath '.required-features.json' -PathType Leaf"
        $block | Should -Match 'ConvertFrom-Json.+-NoEnumerate'
        $block | Should -Match '\$features.Count -eq 0\) \{'
        $block | Should -Match '\$selected -ne \$effective'
        $block | Should -Match '\$env:ARM_CLIENT_ID'
        $block | Should -Match '\$env:ARM_TENANT_ID'
        $block | Should -Match 'Register-AvmFeature -SubscriptionId \$env:SELECTED_SUBSCRIPTION_ID -WhatIf'
        $block | Should -Match '\$preview.FeaturesTotal -ne \$features.Count'
        $block | Should -Match '''required=true'' \| Out-File -FilePath \$env:GITHUB_OUTPUT'
        $script:jobs['e2e-test'] | Should -Match 'run: \*check-required-features'
    }

    It 'installs the module, checks the per-job selection, logs in, registers, then tests in <Job>' -ForEach @(
        @{ Job = 'integration-test'; Test = 'Run integration tests' }
        @{ Job = 'e2e-test'; Test = 'Run end-to-end tests' }
    ) {
        $block = $script:jobs[$Job]
        $names = @(
            'Install Avm.Authoring'
            'Validate required features offline'
            'Azure login for required features'
            'Register required features'
            $Test
        )
        $positions = @($names | ForEach-Object { $block.IndexOf("- name: $_") })
        foreach ($position in $positions) {
            $position | Should -BeGreaterOrEqual 0
        }
        for ($index = 1; $index -lt $positions.Count; $index++) {
            $positions[$index] | Should -BeGreaterThan $positions[$index - 1]
        }
        $block | Should -Match 'avm register-features --subscription-id \$env:SELECTED_SUBSCRIPTION_ID|run: \*register-required-features'
    }
}

Describe 'CI workflow' {
    BeforeAll {
        $workflowRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows'
        $script:ciPath = Join-Path $workflowRoot 'ci-authoring.yml'
        $script:ci = Get-Content -LiteralPath $script:ciPath -Raw
        $script:workflowCi = Get-Content -LiteralPath (Join-Path $workflowRoot 'ci-workflows.yml') -Raw
    }

    It 'disables shared startup JIT profiles before CI PowerShell processes start' {
        $globalEnvironment = [regex]::Match($script:ci, '(?ms)^env:\r?\n(?<body>.*?)(?=^\S|\z)')
        $globalEnvironment.Success | Should -BeTrue
        $globalEnvironment.Groups['body'].Value |
            Should -Match "(?m)^  DOTNET_MultiCoreJitMinNumCpus: '7fffffff'\r?$"
        ([regex]::Matches($script:ci, '(?m)^\s*DOTNET_MultiCoreJitMinNumCpus:')).Count | Should -Be 1
        $script:ci | Should -Match 'run: \./build\.ps1 \$\{\{ matrix\.task \}\}'
        $script:ci | Should -Match 'run: \./build\.ps1 ci-component'
        $script:workflowCi | Should -Match 'run: \./build\.ps1 test-workflows'
        $script:ci | Should -Match 'run: \./build\.ps1 integration'
    }

    It 'keeps workflow-definition tests in a dedicated Ubuntu-only job' {
        $jobMatch = [regex]::Match($script:workflowCi, '(?ms)^  workflows:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $jobMatch.Success | Should -BeTrue
        $jobBlock = $jobMatch.Value

        $jobBlock | Should -Match '(?m)^    runs-on: ubuntu-latest\r?$'
        $jobBlock | Should -Not -Match 'matrix:'
        $jobBlock | Should -Match 'run: \./build\.ps1 test-workflows'
        $jobBlock | Should -Match 'name: test-results-workflows-ubuntu-latest'

        $script:workflowCi | Should -Match '(?m)^    needs: workflows\r?$'
        $script:ci | Should -Not -Match 'test-workflows'
    }

    It 'authenticates tflint plugin downloads so the shared macOS runner egress does not hit the GitHub API rate limit' {
        $script:ci | Should -Match 'GITHUB_TOKEN:\s*\$\{\{ github\.token \}\}'
    }

    It 'runs lint once in a dedicated Ubuntu job while retaining the three-OS test matrix' {
        $lint = [regex]::Match($script:ci, '(?ms)^  lint:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $unit = [regex]::Match($script:ci, '(?ms)^  unit:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $component = [regex]::Match($script:ci, '(?ms)^  component:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $lint.Success | Should -BeTrue
        $unit.Success | Should -BeTrue
        $component.Success | Should -BeTrue
        $lint.Value | Should -Match '(?m)^    runs-on: ubuntu-latest\r?$'
        $lint.Value | Should -Not -Match 'matrix:'
        $lint.Value | Should -Match 'Install-AvmBuildPrerequisites\.ps1 -IncludePSScriptAnalyzer'
        $lint.Value | Should -Match 'run: \./build\.ps1 lint'
        ([regex]::Matches($script:ci, '(?m)run: \./build\.ps1 lint\r?$')).Count | Should -Be 1
        $unit.Value | Should -Match 'os: ubuntu-latest'
        $unit.Value | Should -Match 'os: windows-latest'
        $unit.Value | Should -Match 'os: macos-latest'
        $unit.Value | Should -Match 'task: ci-coverage'
        $unit.Value | Should -Match 'task: ci-unit'
        $unit.Value | Should -Match 'run: \./build\.ps1 \$\{\{ matrix\.task \}\} -TestGroup Authoring'
        $unit.Value | Should -Match 'Upload coverage to GitHub'
        $unit.Value | Should -Match "matrix\.os == 'ubuntu-latest'"
        $unit.Value | Should -Match 'out/coverage/coverage\.cobertura\.xml'
        $component.Value | Should -Match 'os: \[ubuntu-latest, windows-latest, macos-latest\]'
        foreach ($job in @($unit, $component)) {
            $job.Value | Should -Match '(?m)^    timeout-minutes: 25\r?$'
            $job.Value | Should -Match 'fail-fast:\s*false'
            $job.Value | Should -Not -Match 'continue-on-error:\s*true'
            $job.Value | Should -Match 'Install-AvmBuildPrerequisites\.ps1 -IncludePSScriptAnalyzer'
        }
        $component.Value | Should -Match 'run: \./build\.ps1 ci-component -TestGroup Authoring'
    }

    It 'collects coverage in the Ubuntu unit leg without a duplicate test job' {
        $unit = [regex]::Match($script:ci, '(?ms)^  unit:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $unit.Success | Should -BeTrue
        $unit.Value | Should -Match 'task: ci-coverage'
        $unit.Value | Should -Match 'Upload coverage to GitHub'
        $script:ci | Should -Not -Match '(?m)^  coverage:\r?$'
        $script:ci | Should -Not -Match 'coverage-inputs'
        $script:ci | Should -Not -Match 'coverage-input\.zip'
    }

    It 'uses the prerequisite installer in every CI test job type' {
        ([regex]::Matches(
                $script:ci,
                '\./scripts/Install-AvmBuildPrerequisites\.ps1')).Count | Should -Be 6
        ([regex]::Matches(
                $script:workflowCi,
                '\./scripts/Install-AvmBuildPrerequisites\.ps1')).Count | Should -Be 1
    }

    It 'installs pinned Bicep policy dependencies before integration acceptance only' {
        $integration = [regex]::Match($script:ci, '(?ms)^  bicep-integration:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $integration.Success | Should -BeTrue
        $integration.Value | Should -Match 'Install-AvmBuildPrerequisites\.ps1 -IncludeBicepPolicy -Confirm:\$false'
        ([regex]::Matches($script:ci, '-IncludeBicepPolicy')).Count | Should -Be 1
        $integration.Value.IndexOf('-IncludeBicepPolicy') |
            Should -BeLessThan $integration.Value.IndexOf('./build.ps1 integration')
    }

    It 'runs Bicep once per OS without cloud credentials and reports every integration group' {
        $bicep = [regex]::Match($script:ci, '(?ms)^  bicep-integration:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)').Value
        $terraform = [regex]::Match($script:ci, '(?ms)^  integration:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)').Value
        $bicep | Should -Match 'os: \[ubuntu-latest, windows-latest, macos-latest\]'
        $bicep | Should -Match 'integration -IntegrationGroup Bicep'
        $terraform | Should -Match 'integration -IntegrationGroup Terraform'
        $bicep | Should -Not -Match 'environment:|id-token:|azure/login|Add-MpPreference|fixture:'
        $bicep | Should -Match 'if: always\(\)'
        $bicep | Should -Match 'test-results-bicep-integration-'
        $script:ci | Should -Match 'needs: \[unit, component, integration, bicep-integration, native-qualification\]'
    }
}

Describe 'Release workflow' {
    BeforeAll {
        $releasePath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'release.yml'
        $script:release = Get-Content -LiteralPath $releasePath -Raw
    }

    It 'runs on ADO promotion and has a required manual release-tag fallback' {
        $script:release | Should -Match '(?m)^\s+types: \[released\]\r?$'
        $script:release | Should -Match '(?m)^  workflow_dispatch:\r?$'
        $script:release | Should -Match '(?ms)^      release_tag:\r?\n' +
            '        description: .+\r?\n' +
            '        required: true\r?\n' +
            '        type: string\r?$'
    }

    It 'converges both triggers on one selected release tag' {
        $selector = [regex]::Escape(
            '${{ github.event_name == ''release'' && github.event.release.tag_name || inputs.release_tag }}'
        )
        ([regex]::Matches($script:release, $selector)).Count | Should -Be 3
        ([regex]::Matches($script:release, '(?m)^\s+RELEASE_TAG:')).Count | Should -Be 1
    }

    It 'accepts only an existing published full release with the exact selected tag' {
        $script:release | Should -Match '--json tagName,isDraft,isPrerelease,publishedAt,databaseId'
        $script:release | Should -Match '\$release\.tagName -cne \$env:RELEASE_TAG'
        $script:release | Should -Match '\$release\.isDraft -or'
        $script:release | Should -Match '\$release\.isPrerelease -or'
        $script:release | Should -Match '\$release\.publishedAt'
    }

    It 'checks out trusted default-branch publisher code' {
        $script:release | Should -Match 'ref: \$\{\{ github\.event\.repository\.default_branch \}\}'
    }

    It 'downloads release assets and delegates publication to the validated script' {
        $script:release | Should -Match '\./scripts/Save-AvmAuthoringReleaseAssets\.ps1'
        $script:release | Should -Match '-ReleaseId \$release\.databaseId'
        $script:release | Should -Not -Match 'gh release download'
        $script:release | Should -Match '\./scripts/Publish-AvmAuthoring\.ps1'
    }

    It 'preserves environment approval and per-release concurrency' {
        $script:release | Should -Match '(?m)^\s+environment: psgallery\r?$'
        $script:release | Should -Match '(?m)^\s+group: psgallery-\$\{\{'
        $script:release | Should -Match '(?m)^\s+cancel-in-progress: false\r?$'
    }

    It 'does not rebuild, upload, create, edit, or promote the release' {
        $script:release | Should -Not -Match '\./build\.ps1'
        $script:release | Should -Not -Match 'gh release (create|upload|edit)'
        $script:release | Should -Not -Match 'contents: write'
    }
}
