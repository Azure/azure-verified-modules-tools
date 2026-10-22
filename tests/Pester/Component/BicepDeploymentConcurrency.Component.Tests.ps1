#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Deployment.ps1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')

    function Set-IsolationFixture {
        param([string] $Root, [string] $Module, [string] $Case = 'defaults', [string] $Target)
        $directory = Join-Path $Root $Module 'tests' 'e2e' $Case
        $null = New-Item -ItemType Directory -Path $directory -Force
        [IO.File]::WriteAllText((Join-Path $Root $Module 'main.bicep'), 'param name string')
        [IO.File]::WriteAllText((Join-Path $directory 'main.test.bicep'), "param namePrefix string = '#_namePrefix_#'")
        $contract = @{
            version = 1
            evidence = @{
                resources = 'All groups and resources derive from the case naming prefix; nested init/idem names include that prefix.'
                cleanup = 'Only recorded Create operations and run-tagged groups are removed; Read fixtures are not owned.'
                sharedState = 'No external settings or fixtures are mutated except the explicitly declared shared target.'
                identity = 'One case naming ID is stable within init/idem and InPlace; Fresh uses another owned namespace.'
            }
        }
        if ($Target) { $contract.sharedTarget = $Target }
        [IO.File]::WriteAllText((Join-Path $directory 'isolation.json'), (ConvertTo-Json $contract -Depth 5))
        return @{ path = "tests/e2e/$Case/main.test.bicep"; name = $Case; e2eIgnore = $false }
    }

    function Invoke-ConcurrencyFixture {
        param([object[]] $Cases, [switch] $Independent, [switch] $FailAssertions)
        $locks = @{}
        foreach ($case in $Cases) {
            if (-not $locks.ContainsKey($case.concurrencyGroup)) {
                $locks[$case.concurrencyGroup] = [Threading.SemaphoreSlim]::new(1, 1)
            }
        }
        $owners = [Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
        $trace = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        $ready = [Threading.Barrier]::new(2)
        $overlap = [Threading.Barrier]::new(2)
        $allowOverlap = [bool]$Independent
        $failAssertions = [bool]$FailAssertions
        try {
            $Cases | ForEach-Object -Parallel {
                $case = $_
                $locks = $using:locks
                $owners = $using:owners
                $trace = $using:trace
                $ready = $using:ready
                $overlap = $using:overlap
                if (-not $ready.SignalAndWait(10000)) { throw 'Workers did not compete.' }
                $lock = $locks[$_.concurrencyGroup]
                if (-not $lock.Wait(10000)) { throw 'Lifecycle lock did not release.' }
                try {
                    if (-not $owners.TryAdd($_.resourceId, $_.name)) { throw 'A competing case overwrote an owned resource.' }
                    $trace.Enqueue("$($_.name):deploy")
                    if ($using:allowOverlap -and -not $overlap.SignalAndWait(10000)) {
                        throw 'Independent cases could not execute concurrently.'
                    }
                    if (-not $using:allowOverlap) { Start-Sleep -Milliseconds 75 }
                    try {
                        $trace.Enqueue("$($_.name):assert")
                        if ($using:failAssertions) { throw [InvalidOperationException]::new('Fixture assertions failed.') }
                        $trace.Enqueue("$($_.name):post")
                    }
                    catch [InvalidOperationException] {
                        $trace.Enqueue("$($case.name):failed")
                    }
                    if ($owners[$_.resourceId] -cne $_.name) { throw 'Cleanup crossed an ownership boundary.' }
                    $removed = ''
                    if (-not $owners.TryRemove($_.resourceId, [ref]$removed) -or $removed -cne $_.name) {
                        throw 'Cleanup failed to remove only its own resource.'
                    }
                    $trace.Enqueue("$($_.name):cleanup")
                }
                finally { $null = $lock.Release() }
            } -ThrottleLimit 2
            $owners.Count | Should -Be 0
            return $trace.ToArray()
        }
        finally {
            foreach ($lock in $locks.Values) { $lock.Dispose() }
            $ready.Dispose()
            $overlap.Dispose()
        }
    }
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep deployment concurrency policy' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:module = 'avm/res/mock/widget'
        $script:subscription = '11111111-2222-4333-8444-555555555555'
        $script:tenant = '11111111-2222-4333-8444-666666666666'
        $script:tests = @(
            Set-IsolationFixture -Root $script:root -Module $script:module
            Set-IsolationFixture -Root $script:root -Module $script:module -Case second
        )
        [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'), '{}')
        $script:options = @{
            Root = $script:root; ModulePath = $script:module; TestFiles = $script:tests
            FallbackSubscriptionId = $script:subscription; TenantId = $script:tenant
            ModuleClientIds = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006"}'
        }
        Mock -CommandName Get-AvmTool -ModuleName Avm.Authoring -MockWith { [pscustomobject]@{ Status = 'installed'; Path = 'fixture-bicep' } }
        Mock -CommandName Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith {
            [pscustomobject]@{ StdOut = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/subscriptionDeploymentTemplate.json#","resources":[]}' }
        }
    }

    It 'executes independent lifecycles concurrently with <Pool> subscriptions' -ForEach @(
        @{ Pool = 'one' }
        @{ Pool = 'two' }
    ) {
        if ($Pool -eq 'two') {
            $script:options.PoolJson = '[{"id":"11111111-2222-4333-8444-555555555555","name":"first"},{"id":"99999999-2222-4333-8444-555555555555","name":"second"}]'
        }
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        @($matrix.subscriptionKey | Select-Object -Unique).Count | Should -Be $(if ($Pool -eq 'two') { 2 } else { 1 })
        foreach ($entry in $matrix) {
            $entry.isolationMode | Should -BeExactly 'isolated'
            $entry.resourceId = $entry.name
        }
        $trace = @(Invoke-ConcurrencyFixture -Cases $matrix -Independent)
        @($trace[0..1] | Where-Object { $_ -like '*:deploy' }).Count | Should -Be 2
        $again = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $again[0].concurrencyGroup | Should -Not -Be $matrix[0].concurrencyGroup
    }

    It 'protects the same shared target through cleanup across runs and different modules on <Outcome>' -ForEach @(
        @{ Outcome = 'success'; FailAssertions = $false }
        @{ Outcome = 'assertion failure'; FailAssertions = $true }
    ) {
        $target = "/subscriptions/$script:subscription/providers/Microsoft.Mock/settings/singleton"
        $first = Set-IsolationFixture -Root $script:root -Module $script:module -Target $target
        $otherModule = 'avm/ptn/mock/shared'
        $second = Set-IsolationFixture -Root $script:root -Module $otherModule -Target $target.ToUpperInvariant()
        $entries = @(
            Get-AvmWorkflowIsolation -Root $script:root -ModulePath $script:module -TestPath $first.path `
                -TenantId $script:tenant -SubscriptionId $script:subscription
            Get-AvmWorkflowIsolation -Root $script:root -ModulePath $otherModule -TestPath $second.path `
                -TenantId $script:tenant -SubscriptionId '99999999-2222-4333-8444-555555555555'
        )
        $entries[0].concurrencyGroup | Should -BeExactly $entries[1].concurrencyGroup
        $entries[0].name = 'first'
        $entries[1].name = 'second'
        foreach ($entry in $entries) { $entry.resourceId = $target }
        $trace = @(Invoke-ConcurrencyFixture -Cases $entries -FailAssertions:$FailAssertions)
        $winner = $trace[0].Split(':')[0]
        $loser = if ($winner -eq 'first') { 'second' } else { 'first' }
        $completion = if ($FailAssertions) { 'failed' } else { 'post' }
        $trace | Should -Be @("$($winner):deploy", "$($winner):assert", "$($winner):$completion", "$($winner):cleanup",
            "$($loser):deploy", "$($loser):assert", "$($loser):$completion", "$($loser):cleanup")
    }

    It 'does not turn <Scope> into a lock when the template has no mutable resources' -ForEach @(
        @{ Scope = 'tenant' }
        @{ Scope = 'managementGroup' }
        @{ Scope = 'subscription' }
    ) {
        Mock -CommandName Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith {
            [pscustomobject]@{ StdOut = (@{
                        '$schema' = "https://schema.management.azure.com/schemas/2019-08-01/$($Scope)DeploymentTemplate.json#"
                        resources = @()
                    } | ConvertTo-Json -Depth 10) }
        }
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $matrix[0].isolationMode | Should -BeExactly 'isolated'
        $matrix[0].concurrencyGroup | Should -Not -Be $matrix[1].concurrencyGroup
    }

    It 'inspects a lexical parent variable template without an ARM evaluator or an indirection lock' {
        Mock -CommandName Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith {
            [pscustomobject]@{ StdOut = (@{
                        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                        variables = @{ '$fxv#0' = @{ resources = @(@{ type = 'Microsoft.Storage/storageAccounts'; name = '#_namePrefix_#' }) } }
                        resources = @(@{ type = 'Microsoft.Resources/deployments'; properties = @{ template = "[variables('`$fxv#0')]" } })
                    } | ConvertTo-Json -Depth 10) }
        }
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $matrix[0].isolationMode | Should -BeExactly 'isolated'
        $matrix[0].isolationBoundary | Should -BeExactly 'OwnedResourceGroup'
        $matrix[0].concurrencyGroup | Should -Not -Be $matrix[1].concurrencyGroup
    }

    It 'does not unlock a declaration whose test-created groups have no fresh ownership proof' {
        Mock -CommandName Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith {
            [pscustomobject]@{ StdOut = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/subscriptionDeploymentTemplate.json#","resources":[{"type":"Microsoft.Resources/resourceGroups","name":"fixed"}]}' }
        }
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $matrix[0].isolationMode | Should -BeExactly 'fallback'
        $matrix[0].concurrencyGroup | Should -BeExactly "avm-deploy-$script:module-$($matrix[0].subscriptionKey)"
        $matrix[0].isolationDiagnostic | Should -Match 'ownership is not established'
    }

    It 'diagnoses unestablished isolation and rechecks the lifecycle lock before authentication' {
        Remove-Item -LiteralPath (Join-Path $script:root $script:module 'tests/e2e/defaults/isolation.json')
        $output = Get-AvmWorkflowDeploymentMatrix @script:options -WarningVariable diagnostics
        $entry = ($output.deploymentMatrix | ConvertFrom-Json -AsHashtable)[0]
        $entry.isolationMode | Should -BeExactly 'fallback'
        $entry.concurrencyGroup | Should -BeExactly "avm-deploy-$script:module-$($entry.subscriptionKey)"
        $diagnostics -join ' ' | Should -Match 'Isolation is not established'
        $entry.isolationDiagnostic | Should -Match 'legacy fallback serialization'
        $authOptions = $script:options.Clone()
        $authOptions.Remove('TestFiles')
        $null = Get-AvmWorkflowAuthentication @authOptions -TestCase $entry
        $entry.concurrencyGroup = 'different'
        { Get-AvmWorkflowAuthentication @authOptions -TestCase $entry } | Should -Throw '*lifecycle lock changed*'
    }

    It 'preserves legacy subscription granularity instead of serializing unrelated unverified allocations' {
        foreach ($test in $script:tests) {
            Remove-Item -LiteralPath (Join-Path $script:root $script:module (Split-Path $test.path -Parent) 'isolation.json')
        }
        $script:options.PoolJson = '[{"id":"11111111-2222-4333-8444-555555555555","name":"first"},{"id":"99999999-2222-4333-8444-555555555555","name":"second"}]'
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        foreach ($entry in $matrix) {
            $entry.isolationMode | Should -BeExactly 'fallback'
            $entry.resourceId = $entry.name
        }
        $trace = @(Invoke-ConcurrencyFixture -Cases $matrix -Independent)
        @($trace[0..1] | Where-Object { $_ -like '*:deploy' }).Count | Should -Be 2
        $script:options.Remove('PoolJson')
        $same = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $same[0].concurrencyGroup | Should -BeExactly $same[1].concurrencyGroup
    }

    It 'retains a legacy module fallback without imposing it on verified cases' {
        Mock -CommandName Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith {
            $resources = if ($ArgumentList[1] -like '*defaults*') { @(@{ type = 'Microsoft.Mock/settings'; name = 'fixed' }) } else { @() }
            [pscustomobject]@{ StdOut = (@{
                        '$schema' = 'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#'
                        resources = $resources
                    } | ConvertTo-Json -Depth 10) }
        }
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $matrix[0].isolationMode | Should -BeExactly 'fallback'
        $matrix[0].concurrencyGroup | Should -BeExactly "avm-deploy-$script:module-$($matrix[0].subscriptionKey)"
        $matrix[0].fallbackModuleLock | Should -BeTrue
        $matrix[1].isolationMode | Should -BeExactly 'isolated'
        $matrix[1].concurrencyGroup | Should -Not -Be $matrix[0].concurrencyGroup
        $authOptions = $script:options.Clone()
        $authOptions.Remove('TestFiles')
        $null = Get-AvmWorkflowAuthentication @authOptions -TestCase $matrix[0]
        $matrix[0].fallbackModuleLock = $false
        { Get-AvmWorkflowAuthentication @authOptions -TestCase $matrix[0] } | Should -Throw '*lifecycle lock changed*'
    }

    It 'does not introduce a repository-wide lock between unrelated unverified modules' {
        $otherModule = 'avm/res/mock/another-widget'
        $other = Set-IsolationFixture -Root $script:root -Module $otherModule
        $entries = @()
        foreach ($module in @($script:module, $otherModule)) {
            Remove-Item -LiteralPath (Join-Path $script:root $module (Split-Path $other.path -Parent) 'isolation.json')
            $entry = Get-AvmWorkflowIsolation -Root $script:root -ModulePath $module -TestPath $other.path `
                -TenantId $script:tenant -SubscriptionId $script:subscription
            $entry.isolationMode | Should -BeExactly 'fallback'
            $entry.name = $module
            $entry.resourceId = $module
            $entries += $entry
        }
        $trace = @(Invoke-ConcurrencyFixture -Cases $entries -Independent)
        @($trace[0..1] | Where-Object { $_ -like '*:deploy' }).Count | Should -Be 2
    }

    It 'does not make locally inspectable indirection a module-wide fallback' {
        foreach ($test in $script:tests) {
            Remove-Item -LiteralPath (Join-Path $script:root $script:module (Split-Path $test.path -Parent) 'isolation.json')
        }
        Mock -CommandName Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith {
            [pscustomobject]@{ StdOut = (@{
                        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                        variables = @{ '$fxv#0' = @{ resources = @() } }
                        resources = @(@{ type = 'Microsoft.Resources/deployments'; properties = @{ template = "[variables('`$fxv#0')]" } })
                    } | ConvertTo-Json -Depth 10) }
        }
        $matrix = (Get-AvmWorkflowDeploymentMatrix @script:options).deploymentMatrix | ConvertFrom-Json -AsHashtable
        $matrix[0].isolationMode | Should -BeExactly 'fallback'
        $matrix[0].fallbackModuleLock | Should -BeFalse
        $matrix[0].concurrencyGroup | Should -BeExactly "avm-deploy-$script:module-$($matrix[0].subscriptionKey)"
    }

    It 'rejects incomplete declarations rather than mistaking a naming flag for proof' {
        $path = Join-Path $script:root $script:module 'tests/e2e/defaults/isolation.json'
        [IO.File]::WriteAllText($path, '{"version":1,"evidence":{"resources":"unique names"}}')
        { Get-AvmWorkflowDeploymentMatrix @script:options } | Should -Throw '*four reviewed ownership evidence*'
    }

    It 'binds subscription-relative targets without serializing different targets' {
        $test = Set-IsolationFixture -Root $script:root -Module $script:module `
            -Target '/subscriptions/#_subscriptionId_#/providers/Microsoft.Mock/settings/singleton'
        $first = Get-AvmWorkflowIsolation -Root $script:root -ModulePath $script:module -TestPath $test.path `
            -TenantId $script:tenant -SubscriptionId $script:subscription
        $second = Get-AvmWorkflowIsolation -Root $script:root -ModulePath $script:module -TestPath $test.path `
            -TenantId $script:tenant -SubscriptionId '99999999-2222-4333-8444-555555555555'
        $first.concurrencyGroup | Should -Not -Be $second.concurrencyGroup
        $first.concurrencyGroup | Should -Not -Match $script:subscription
    }

    It 'rejects malformed or ambiguous reviewed inputs: <Kind>' -ForEach @(
        @{ Kind = 'duplicate fields'; Json = '{"version":1,"version":1,"evidence":{}}' }
        @{ Kind = 'extra fields'; Json = '{"version":1,"isolated":true,"evidence":{}}' }
        @{ Kind = 'boolean version'; Json = '{"version":true,"evidence":{}}' }
    ) {
        [IO.File]::WriteAllText((Join-Path $script:root $script:module 'tests/e2e/defaults/isolation.json'), $Json)
        { Get-AvmWorkflowDeploymentMatrix @script:options } | Should -Throw
    }

    It 'rejects an unsupported shared-target token rather than broadening a lock' {
        $test = Set-IsolationFixture -Root $script:root -Module $script:module `
            -Target '/providers/Microsoft.Mock/settings/#_module_#'
        { Get-AvmWorkflowIsolation -Root $script:root -ModulePath $script:module -TestPath $test.path `
                -TenantId $script:tenant -SubscriptionId $script:subscription } | Should -Throw '*unsupported token*'
    }
}

Describe 'Component: Bicep reviewed isolation effective inputs' -Tag Component {
    BeforeEach {
        $script:environment = @{}
        foreach ($name in @('AVM_CI_VARIABLES', 'AVM_CI_SECRETS', 'CI_KEY_VAULT_NAME', 'localToken_customFixture')) {
            $script:environment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value)
        }
        $script:compiled = '{"parameters":{"resourceGroupName":{"type":"string"},"namePrefix":{"type":"string"}}}'
    }
    AfterEach {
        foreach ($name in @($script:environment.Keys)) {
            $value = $script:environment[$name]
            [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
        }
    }

    It 'rejects effective naming overrides using the native CI alias resolver: <Alias>' -ForEach @(
        @{ Alias = 'CI_RESOURCE_GROUP_NAME' }
        @{ Alias = 'CI__resourceGroupName' }
        @{ Alias = 'ci_NAME_PREFIX' }
    ) {
        $env:AVM_CI_SECRETS = @{ $Alias = 'do-not-log-this-value' } | ConvertTo-Json -Compress
        $failure = $null
        try { Assert-AvmWorkflowIsolationInput -IsolationMode isolated -CompiledTemplate $script:compiled }
        catch { $failure = $_ }
        $failure.Exception.Message | Should -BeLike '*does not allow CI parameter overrides*'
        $failure.Exception.Message | Should -Not -Match 'do-not-log-this-value'
    }

    It 'allows unrelated CI inputs but rejects implicit vault and custom-token overrides' {
        $env:AVM_CI_VARIABLES = '{"CI_OTHER_MODULE_INPUT":"unused"}'
        { Assert-AvmWorkflowIsolationInput -IsolationMode shared -CompiledTemplate $script:compiled } | Should -Not -Throw
        $env:CI_KEY_VAULT_NAME = 'fixture'
        { Assert-AvmWorkflowIsolationInput -IsolationMode isolated -CompiledTemplate $script:compiled } |
            Should -Throw '*implicit CI Key Vault*'
        [Environment]::SetEnvironmentVariable('CI_KEY_VAULT_NAME', [NullString]::Value)
        $env:localToken_customFixture = 'fixed-resource'
        { Assert-AvmWorkflowIsolationInput -IsolationMode isolated -CompiledTemplate $script:compiled } |
            Should -Throw '*custom localToken*'
        { Assert-AvmWorkflowIsolationInput -IsolationMode fallback -CompiledTemplate $script:compiled } | Should -Not -Throw
    }

    It 'uses the native bounded suffix rather than a full GUID in provider-limited names' {
        (Get-AvmWorkflowNamePrefix -IsolationMode isolated -Prefix gci) | Should -BeExactly 'gci#_avmE2eSuffix_#'
        (Get-AvmWorkflowNamePrefix -IsolationMode fallback -Prefix 'legacy-prefix') | Should -BeExactly ''
        { Get-AvmWorkflowNamePrefix -IsolationMode isolated -Prefix 'too-long' } | Should -Throw '*one to three*'
        InModuleScope Avm.Authoring {
            $tokens = Get-AvmBicepTestTokenMap -Root '.' -SubscriptionId '11111111-2222-4333-8444-555555555555' `
                -RunId ('a' * 32) -DefaultTokens @{ namePrefix = 'gci#_avmE2eSuffix_#' }
            $tokens['namePrefix'] | Should -BeExactly ('gci' + ('a' * 10))
            ($tokens['namePrefix'] + 'example001').Length | Should -BeLessOrEqual 32
        }
    }

    It 'rejects shared-target retention before login instead of releasing a lock without cleanup' {
        { Assert-AvmWorkflowIsolationInput -IsolationMode shared -CompiledTemplate $script:compiled -RemoveDeployment $false } |
            Should -Throw '*requires cleanup before releasing*'
        { Assert-AvmWorkflowIsolationInput -IsolationMode isolated -CompiledTemplate $script:compiled -RemoveDeployment $false } |
            Should -Not -Throw
    }
}

Describe 'Component: Bicep concurrent-case native ownership' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:nativeOptions = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:nativeOptions.RequireResourceIsolation = $true
        $script:fixture.UseGeneratedNames = $true
        $script:prefixBefore = [Environment]::GetEnvironmentVariable('localToken_namePrefix')
        $env:localToken_namePrefix = Get-AvmWorkflowNamePrefix -IsolationMode isolated -Prefix gci
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('localToken_namePrefix',
            $(if ($null -eq $script:prefixBefore) { [NullString]::Value } else { $script:prefixBefore }))
        Remove-NativeBicepWorkflowFixture -Fixture $script:fixture
    }

    It 'distinguishes repeated case runs and cleans only their generated resources and groups' {
        $ids = @()
        $names = @()
        foreach ($run in 1..2) {
            $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
            $result.Status | Should -Be 'pass'
            $state = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
            $state.status | Should -Be 'Complete'
            $ids += $state.runId
            $names += $script:fixture.CreatedId
            $groupId = $script:fixture.CreatedId.Split('/providers/')[0]
            $script:fixture.Calls | Should -Contain "remove:$groupId"
            $state.resources.id | Should -Contain $script:fixture.CreatedId
            $script:fixture.StatePath = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
            $script:nativeOptions.CleanupStatePath = $script:fixture.StatePath
        }
        $ids[0] | Should -Not -Be $ids[1]
        $names[0] | Should -Not -Be $names[1]
        foreach ($name in $names) { $name | Should -Match '/storageAccounts/gci[0-9a-f]{10}$' }
    }

    It 'keeps naming identity stable for InPlace validation and deployment' {
        InModuleScope Avm.Authoring { Mock Get-AvmBicepDeploymentRetryKind { 'Transient' } }
        $script:fixture.RetrySequence.Enqueue('Transient')
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -Be 'pass'
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 2
        $creates[0].DeploymentName | Should -BeExactly $creates[1].DeploymentName
        $creates[0].ResourceGroupName | Should -BeExactly $creates[1].ResourceGroupName
        $creates[0].Content | Should -BeExactly $creates[1].Content
        $state = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $state.attempts.mode | Should -Be @('Initial', 'InPlace')
    }

    It 'changes only the fresh naming context and retains both attempts until final cleanup' {
        $script:nativeOptions.Remove('ResourceLocation')
        $script:fixture.RetrySequence.Enqueue('Regional')
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -Be 'pass'
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 2
        $creates[0].DeploymentName | Should -Not -Be $creates[1].DeploymentName
        $creates[0].ResourceGroupName | Should -Not -Be $creates[1].ResourceGroupName
        $firstName = ($creates[0].Content | ConvertFrom-Json).resources[0].name
        $secondName = ($creates[1].Content | ConvertFrom-Json).resources[0].name
        $firstName | Should -Not -Be $secondName
        $firstName | Should -Match '^gci[0-9a-f]{10}$'
        $secondName | Should -Match '^gci[0-9a-f]{10}$'
        $history = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $history.attempts.mode | Should -Be @('Initial', 'Fresh')
        $history.status | Should -BeExactly 'Complete'
        $lastSubmit = $script:fixture.Calls.LastIndexOf('create')
        $firstRemoval = @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' })[0]
        $script:fixture.Calls.IndexOf($firstRemoval) | Should -BeGreaterThan $lastSubmit
    }

    It 'cleans the failed case without deleting a referenced resource outside its ownership' {
        $script:fixture.PesterMode = 'fail'
        [IO.File]::WriteAllText((Join-Path $script:fixture.Directory 'resources.tests.ps1'), '')
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -BeExactly 'fail'
        $script:fixture.Calls | Should -Contain "remove:$($script:fixture.CreatedId.Split('/providers/')[0])"
        $script:fixture.Calls | Should -Not -Contain "remove:$($script:fixture.CreatedId)-existing"
        $state = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $state.resources.id | Should -Contain $script:fixture.CreatedId
        $state.resources.id | Should -Not -Contain "$($script:fixture.CreatedId)-existing"
        $state.status | Should -BeExactly 'Complete'
    }

    It 'refuses a pre-existing harness group before validation or submission' {
        $script:fixture.GroupExists = $true
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -BeExactly 'fail'
        $result.Issues.Message -join ' ' | Should -Match 'Refusing to use existing resource group'
        @($script:fixture.NativeInputs).Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'refuses cleanup after group ownership changes, including child removal' {
        $script:fixture.RetagDuringMetadata = $true
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -BeExactly 'fail'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        $result.CleanupPending.Count | Should -BeGreaterThan 0
    }

    It 'refuses submission when the freshly created group no longer has the expected owner' {
        $script:fixture.OwnershipMismatch = $true
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -BeExactly 'fail'
        $result.Issues.Message -join ' ' | Should -Match 'ownership changed'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'refuses out-of-bound operation traversal and does not delete another group' {
        $foreign = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/foreign/providers/Microsoft.Resources/deployments/shared'
        $script:fixture.AdditionalRootResources = @($foreign)
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -BeExactly 'fail'
        $result.Issues.Message -join ' ' | Should -Match 'outside the verified ownership boundary'
        @($script:fixture.RestInputs | Where-Object { $_.Path -like "$foreign/*" }).Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*foreign*' }).Count | Should -Be 0
    }

    It 'persists the boundary through state-only recovery and refuses tampered ownership provenance' {
        $script:nativeOptions.Phase = 'Deploy'
        $result = Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs
        $result.Status | Should -BeExactly 'pass'
        $original = [IO.File]::ReadAllText($script:fixture.StatePath)
        $state = $original | ConvertFrom-Json -AsHashtable
        $state.schemaVersion | Should -Be 2
        $state.isolationBoundary | Should -BeExactly 'OwnedResourceGroup'
        $cleanup = @{
            StatePath = $script:fixture.StatePath; SubscriptionId = $script:nativeOptions.SubscriptionId
            TenantId = $script:nativeOptions.TenantId; SkipModuleVersionCheck = $true
        }
        $state.resources = @(@{
                id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/foreign/providers/Microsoft.Storage/storageAccounts/shared'
                removed = $false; postProcessed = $false; metadataCaptured = $false
                managedResourceGroupIds = @(); originalSoftDeleteFeatureState = ''
            })
        [IO.File]::WriteAllText($script:fixture.StatePath, (ConvertTo-Json $state -Depth 30))
        { Invoke-AvmTestCleanup @cleanup -Confirm:$false } | Should -Throw '*outside the verified ownership boundary*'
        $state = $original | ConvertFrom-Json -AsHashtable
        $state.ownedResourceGroups = @()
        [IO.File]::WriteAllText($script:fixture.StatePath, (ConvertTo-Json $state -Depth 30))
        { Invoke-AvmTestCleanup @cleanup -Confirm:$false } | Should -Throw '*outside the verified ownership boundary*'
        $state = $original | ConvertFrom-Json -AsHashtable
        $state.Remove('isolationBoundary')
        [IO.File]::WriteAllText($script:fixture.StatePath, (ConvertTo-Json $state -Depth 30))
        { Invoke-AvmTestCleanup @cleanup -Confirm:$false } | Should -Throw '*Unsupported Bicep cleanup state version*'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        [IO.File]::WriteAllText($script:fixture.StatePath, $original)
        (Invoke-AvmTestCleanup @cleanup -Confirm:$false).Status | Should -BeExactly 'pass'
        $restored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $restored.isolationBoundary | Should -BeExactly 'OwnedResourceGroup'
        $restored.status | Should -BeExactly 'Complete'
    }

    It 'rejects unproved provider infrastructure and scope escapes before Azure access' -ForEach @(
        @{ Resource = @{ type = 'Microsoft.App/managedEnvironments'; name = 'unproved' } }
        @{ Resource = @{ type = 'Microsoft.Storage/storageAccounts'; name = 'example'; scope = '/subscriptions/foreign' } }
        @{ Resource = @{ type = 'Microsoft.Resources/deployments'; properties = @{ templateLink = @{ uri = 'https://example.invalid/template' } } } }
    ) {
        $script:fixture.Resources = @($Resource)
        { Invoke-AvmTestE2e @script:nativeOptions -UseCiInputs } | Should -Throw '*Isolation*'
        @($script:fixture.NativeInputs).Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -eq 'group-create' -or $_ -like 'remove:*' }).Count | Should -Be 0
    }
}
