BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:entryPath = Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'Invoke-BicepTestTenantSync.ps1'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $workflow = (Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'repository-management-bicep-sync.yml') -Raw).Replace("`r`n", "`n")
    $run = [regex]::Match($workflow, '(?ms)^        run: \|\n(?<body>.*)\z')
    if (-not $run.Success) { throw 'The Bicep publication run script is missing.' }
    $script:workflowRun = [scriptblock]::Create(($run.Groups['body'].Value -replace '(?m)^ {10}', ''))
    $script:sourceValues = [ordered]@{
        TEST_BAMI_TENANT_ID = '11111111-1111-4111-8111-111111111111'
        TEST_BAMI_CONTROLLER_CLIENT_ID = '22222222-2222-4222-8222-222222222222'
        TEST_BAMI_ADMIN_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
        TEST_BAMI_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject @(
            1..28 | ForEach-Object {
                @{ name = "bami-sub-$_"; id = ('66666666-6666-4666-8666-{0:d12}' -f $_) }
            }
        ) -Depth 5 -Compress
        TEST_BAMI_MANAGEMENT_GROUP_ID = 'bami-test'
        TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = 'rg-bami-test'
        TEST_BAMI_BICEP_CLIENT_ID = '44444444-4444-4444-8444-444444444444'
        TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = '55555555-5555-4555-8555-555555555555'
    }
    $script:originalEnvironment = @{}
    foreach ($variableName in (@($script:sourceValues.Keys) + @(
        'GH_TOKEN', 'AVM_OFFLINE', 'AVM_APP_SLUG', 'GITHUB_WORKSPACE',
        'GITHUB_REPOSITORY', 'GITHUB_REF', 'GITHUB_EVENT_NAME',
        'AVM_BAMI_TEST_TENANT_SYNC_ENABLED', 'PLAN_ONLY'
    ))) {
        $script:originalEnvironment[$variableName] = [System.Environment]::GetEnvironmentVariable($variableName)
    }

    function New-BicepEntryVariable {
        param([string] $Name, [string] $Value, [int] $Revision = 0)

        @{
            name = $Name
            value = $Value
            created_at = '2026-09-01T00:00:00Z'
            updated_at = [datetime]::new(2026, 9, 15, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds($Revision).ToString('O')
        }
    }
}

Describe 'Bicep test tenant entry point with real configuration and mocked GitHub' -Tag Component {
    BeforeEach {
        foreach ($variableName in $script:sourceValues.Keys) {
            [System.Environment]::SetEnvironmentVariable($variableName, $script:sourceValues[$variableName])
        }
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '0'
        $env:AVM_APP_SLUG = 'azure-verified-modules'
        $env:GITHUB_WORKSPACE = $script:root
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_EVENT_NAME = $null
        $env:AVM_BAMI_TEST_TENANT_SYNC_ENABLED = $null
        $env:PLAN_ONLY = $null
        $script:entryState = @{
            Variables = [ordered]@{
                ARM_TENANT_ID = New-BicepEntryVariable -Name 'ARM_TENANT_ID' -Value 'legacy-value'
                TEST_BAMI_CONTROLLER_CLIENT_ID = New-BicepEntryVariable -Name 'TEST_BAMI_CONTROLLER_CLIENT_ID' -Value 'existing-value-not-owned-by-this-sync'
            }
            WriteNames = [System.Collections.Generic.List[string]]::new()
            LostSelectorResponse = $false
            BlockedExecutable = Join-Path $TestDrive 'gh-must-never-start'
        }
        $entryState = $script:entryState
        $newVariable = ${function:New-BicepEntryVariable}
        Mock Import-Module {}
        Mock Get-Command ({ [pscustomobject]@{ Source = $entryState.BlockedExecutable } }.GetNewClosure()) -ParameterFilter {
            $Name -ceq 'gh' -and $CommandType -eq 'Application'
        }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList, $EnvVars)
            $FilePath | Should -BeExactly $entryState.BlockedExecutable
            $ArgumentList[0] | Should -BeExactly 'api'
            $ArgumentList[2] | Should -BeExactly 'github.com'
            $EnvVars.GH_TOKEN | Should -BeExactly 'fixture-installation-token'
            if ($ArgumentList[4] -ceq 'GET') {
                $ArgumentList[11] | Should -BeExactly 'repos/Azure/bicep-registry-modules/actions/variables?per_page=100&page=1'
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut = ConvertTo-Json -InputObject @{
                        total_count = $entryState.Variables.Count
                        variables = @($entryState.Variables.Values)
                    } -Depth 10 -Compress
                    StdErr = ''
                }
            }
            $ArgumentList[4] | Should -BeIn @('POST', 'PATCH')
            $ArgumentList[12] | Should -BeExactly '--raw-field'
            $ArgumentList[13] | Should -BeLike 'name=TEST_BAMI_*'
            $ArgumentList[14] | Should -BeExactly '--raw-field'
            $ArgumentList[15] | Should -BeLike 'value=*'
            $variableName = $ArgumentList[13].Substring(5)
            $variableName | Should -BeIn @(
                'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_SUBSCRIPTION_IDS',
                'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID', 'TEST_BAMI_MODULE_PATHS'
            )
            $entryState.WriteNames.Add($variableName)
            $entryState.Variables[$variableName] = & $newVariable -Name $variableName `
                -Value $ArgumentList[15].Substring(6) -Revision $entryState.WriteNames.Count
            if ($entryState.LostSelectorResponse -and $variableName -ceq 'TEST_BAMI_MODULE_PATHS') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Response lost (HTTP 502)' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }.GetNewClosure())
    }

    AfterEach {
        foreach ($variableName in $script:originalEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($variableName, $script:originalEnvironment[$variableName])
        }
    }

    It 'plans <Mode> from any working directory without writing variables' -ForEach @(
        @{ Mode = 'by default'; Options = @{} }
        @{ Mode = 'with explicit PlanOnly'; Options = @{ PlanOnly = $true } }
    ) {
        Push-Location $TestDrive
        try { $result = & $script:entryPath @Options | ConvertFrom-Json -AsHashtable }
        finally { Pop-Location }
        $result.Status | Should -BeExactly 'Planned'
        $result.PlanOnly | Should -BeTrue
        $result.ChangedNames | Should -HaveCount 6
        $script:entryState.WriteNames | Should -HaveCount 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[4] -ceq 'GET' }
    }

    It 'applies the real central canary selector last and leaves all unrelated variables untouched' {
        $result = & $script:entryPath -Apply | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Published'
        $script:entryState.WriteNames | Should -HaveCount 6
        $script:entryState.WriteNames[-1] | Should -BeExactly 'TEST_BAMI_MODULE_PATHS'
        $script:entryState.Variables.TEST_BAMI_MODULE_PATHS.value |
            Should -BeExactly '["avm/res/dev-test-lab/lab"]'
        foreach ($variableName in @(
            'TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID',
            'TEST_BAMI_MANAGEMENT_GROUP_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
        )) {
            $script:entryState.Variables[$variableName].value | Should -BeExactly $script:sourceValues[$variableName]
        }
        $subscriptions = $script:entryState.Variables.TEST_BAMI_SUBSCRIPTION_IDS.value | ConvertFrom-Json -AsHashtable
        $subscriptions | Should -HaveCount 28
        @($subscriptions[0].Keys | Sort-Object) | Should -Be @('id', 'name')
        $script:entryState.Variables.ARM_TENANT_ID.value | Should -BeExactly 'legacy-value'
        $script:entryState.Variables.TEST_BAMI_CONTROLLER_CLIENT_ID.value | Should -BeExactly 'existing-value-not-owned-by-this-sync'
        $script:entryState.Variables.Contains('TEST_BAMI_ADMIN_SUBSCRIPTION_ID') | Should -BeFalse
        $script:entryState.Variables.Contains('TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME') | Should -BeFalse
        $result | ConvertTo-Json -Depth 5 | Should -Not -Match 'fixture-installation-token|11111111|22222222|33333333|rg-bami-test'
    }

    It 'publishes from the actual <EventName> workflow command with no inputs and retired flag <FlagState>' -ForEach @(
        @{ EventName = 'schedule'; FlagState = 'absent'; LegacyFlag = $null }
        @{ EventName = 'workflow_dispatch'; FlagState = 'absent'; LegacyFlag = $null }
        @{ EventName = 'schedule'; FlagState = 'false'; LegacyFlag = 'false' }
        @{ EventName = 'workflow_dispatch'; FlagState = 'false'; LegacyFlag = 'false' }
    ) {
        $env:GITHUB_EVENT_NAME = $EventName
        $env:AVM_BAMI_TEST_TENANT_SYNC_ENABLED = $LegacyFlag
        $env:PLAN_ONLY = if ($LegacyFlag) { 'true' } else { $null }
        $result = & $script:workflowRun | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Published'
        $result.PlanOnly | Should -BeFalse
        $result.Target | Should -BeExactly 'Azure/bicep-registry-modules'
        $script:entryState.WriteNames | Should -HaveCount 6
        $script:entryState.WriteNames[-1] | Should -BeExactly 'TEST_BAMI_MODULE_PATHS'
        $script:entryState.Variables.TEST_BAMI_MODULE_PATHS.value | Should -BeExactly '["avm/res/dev-test-lab/lab"]'
        $script:entryState.Variables.ARM_TENANT_ID.value | Should -BeExactly 'legacy-value'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 15 -ParameterFilter { $ArgumentList[4] -ceq 'GET' }
    }

    It 'rejects an incorrect or missing App slug before the workflow can publish' -ForEach @(
        'another-app', 'Azure-Verified-Modules', ''
    ) {
        $env:AVM_APP_SLUG = $_
        { & $script:workflowRun } | Should -Throw '*not azure-verified-modules*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        $script:entryState.WriteNames | Should -HaveCount 0
    }

    It 'validates the workflow source bundle before reading or writing variables' {
        $env:TEST_BAMI_TENANT_ID = 'invalid-tenant'
        { & $script:workflowRun } | Should -Throw
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        $script:entryState.WriteNames | Should -HaveCount 0
    }

    It 'propagates WhatIf as a write-free preview' {
        $result = & $script:entryPath -Apply -WhatIf | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Preview'
        $script:entryState.WriteNames | Should -HaveCount 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[4] -ceq 'GET' }
    }

    It 'validates all source values before any mocked API call at the entry point' {
        $env:TEST_BAMI_CONTROLLER_CLIENT_ID = $env:TEST_BAMI_BICEP_CLIENT_ID
        { & $script:entryPath -Apply } | Should -Throw
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        $script:entryState.WriteNames | Should -HaveCount 0
    }

    It 'does not turn a lost selector response into a successful entry-point result' {
        $script:entryState.LostSelectorResponse = $true
        { & $script:entryPath -Apply } |
            Should -Throw '*Readback confirms the requested selector and unchanged execution values are present*'
        $script:entryState.WriteNames | Should -HaveCount 6
        $script:entryState.Variables.TEST_BAMI_MODULE_PATHS.value |
            Should -BeExactly '["avm/res/dev-test-lab/lab"]'
    }
}

Describe 'Bicep variable readback across a real process boundary' -Tag Component {
    BeforeAll {
        . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RetryHelpers.ps1')
        . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'GitHubVariables.ps1')
        . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'TestTenantSync.ps1')
        $script:realRepositoryProcess = ${function:Invoke-RepositorySyncProcess}
        $script:pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    }

    BeforeEach {
        $env:GH_TOKEN = 'fixture-installation-token'
        $env:AVM_OFFLINE = '0'
        $script:boundaryWaits = [System.Collections.Generic.List[int]]::new()
        Mock Start-Sleep { param($Seconds) $script:boundaryWaits.Add($Seconds) }
        $script:boundaryStatePath = Join-Path $TestDrive 'variables.json'
        $fixturePath = Join-Path $TestDrive 'variables-process.ps1'
        Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM -Value @'
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$arguments = @($args)
if ($env:GH_TOKEN -cne 'fixture-installation-token' -or $arguments[0] -cne 'api' -or $arguments[2] -cne 'github.com') {
    throw 'Unexpected fixture process invocation.'
}
$statePath = $env:AVM_BICEP_VARIABLE_TEST_STATE
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$endpoint = 'repos/Azure/bicep-registry-modules/actions/variables'
$method = $arguments[4]
if ($method -ceq 'GET') {
    if ($arguments.Count -ne 12 -or $arguments[11] -cne "${endpoint}?per_page=100&page=1") { throw 'Unexpected read.' }
    $state.Reads++
    $variable = $state.Variable
    if ($state.Writes -gt 0) {
        $state.Readbacks++
        if ($state.Readbacks -eq 1) { $variable = $state.Previous }
    }
    $variables = @(
        @{ name = 'TEST_BAMI_MODULE_PATHS'; value = '[]'; created_at = '2026-09-01T00:00:00Z'; updated_at = '2026-09-01T00:00:00Z' }
        if ($null -ne $variable) { $variable }
    )
    $response = @{ total_count = $variables.Count; variables = $variables }
}
elseif ($method -cin @('POST', 'PATCH')) {
    if ($method -ceq 'PATCH') { $endpoint += '/TEST_BAMI_SUBSCRIPTION_IDS' }
    if ($arguments.Count -ne 16 -or $arguments[11] -cne $endpoint -or
        $arguments[12] -cne '--raw-field' -or $arguments[13] -cne 'name=TEST_BAMI_SUBSCRIPTION_IDS' -or
        $arguments[14] -cne '--raw-field' -or -not $arguments[15].StartsWith('value=')) { throw 'Unexpected write.' }
    $state.Writes++
    $state.Request = $arguments
    $state.Previous = $state.Variable
    $state.Variable = @{
        name = 'TEST_BAMI_SUBSCRIPTION_IDS'
        value = $arguments[15].Substring(6)
        created_at = if ($null -ne $state.Previous) { $state.Previous.created_at } else { '2026-09-24T00:00:00Z' }
        updated_at = '2026-09-24T00:00:00Z'
    }
}
else { throw 'Unexpected method.' }
[System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
if ($method -ceq 'GET') { $response | ConvertTo-Json -Depth 10 -Compress }
'@
        $realProcess = $script:realRepositoryProcess
        $pwsh = $script:pwsh
        $statePath = $script:boundaryStatePath
        Mock Invoke-RepositorySyncProcess ({
            param($Command, $Arguments, $EnvVars, $TimeoutSec)
            if ($Command -cne 'gh') { throw 'Only the GitHub adapter may call the fixture.' }
            $environment = $EnvVars.Clone()
            $environment.AVM_BICEP_VARIABLE_TEST_STATE = $statePath
            & $realProcess -Command $pwsh -Arguments (@('-NoProfile', '-NonInteractive', '-File', $fixturePath) + $Arguments) `
                -EnvVars $environment -TimeoutSec $TimeoutSec
        }.GetNewClosure())
        Mock Get-Command ({
            param($Name)
            if ($Name -cne $pwsh) { throw 'Only the offline fixture executable may start.' }
            [pscustomobject]@{ Source = $pwsh }
        }.GetNewClosure()) -ParameterFilter { $CommandType -eq 'Application' }
    }

    AfterEach {
        foreach ($variableName in $script:originalEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($variableName, $script:originalEnvironment[$variableName])
        }
    }

    It 'preserves all 28 JSON objects through a real <Method> process and delayed collection readback' -ForEach @(
        @{ Method = 'POST' }
        @{ Method = 'PATCH' }
    ) {
        $value = $script:sourceValues.TEST_BAMI_SUBSCRIPTION_IDS
        $state = @{
            Variable = if ($Method -ceq 'PATCH') { New-BicepEntryVariable -Name 'TEST_BAMI_SUBSCRIPTION_IDS' -Value $value.Replace('bami-sub-1"', 'previous-sub-1"') } else { $null }
            Previous = $null
            Writes = 0
            Reads = 0
            Readbacks = 0
            Request = @()
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:boundaryStatePath -Encoding utf8NoBOM
        $expected = Get-AvmBicepTestTenantSnapshot
        $actual = Set-AvmBicepTestTenantVariable -Expected $expected -Name 'TEST_BAMI_SUBSCRIPTION_IDS' -Value $value
        $actual.TEST_BAMI_SUBSCRIPTION_IDS.Value | Should -BeExactly $value
        @($actual.TEST_BAMI_SUBSCRIPTION_IDS.Value | ConvertFrom-Json) | Should -HaveCount 28
        $actual.TEST_BAMI_MODULE_PATHS.Value | Should -BeExactly '[]'
        $state = Get-Content -LiteralPath $script:boundaryStatePath -Raw | ConvertFrom-Json -AsHashtable
        $state.Request[4] | Should -BeExactly $Method
        $state.Request[15] | Should -BeExactly "value=$value"
        $state.Writes | Should -Be 1
        $state.Reads | Should -Be 4
        $state.Readbacks | Should -Be 2
        $script:boundaryWaits | Should -Be @(5)
    }
}
