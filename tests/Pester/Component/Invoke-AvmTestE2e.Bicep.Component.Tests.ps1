#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native end-to-end workflow' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'uses native validation, recorded deployment, exact operations and durable cleanup state' {
        $source = Join-Path $script:fixture.Directory 'main.test.bicep'
        $before = [IO.File]::ReadAllBytes($source)
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.RunsPassed | Should -Be 1
        $result.AssertionResults[0].Status | Should -Be 'not-present'
        $result.PostResults[0].Status | Should -Be 'not-present'
        $result.CleanupPending | Should -BeNullOrEmpty
        $result.CleanupStatePaths | Should -Be @($script:fixture.StatePath)
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json -AsHashtable
        $stored['status'] | Should -Be 'Complete'
        $stored['case']['completionStarted'] | Should -BeTrue
        $stored['deployments'][0]['status'] | Should -Be 'Succeeded'
        @($stored['resources'] | Where-Object { -not $_['postProcessed'] }).Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*-existing' }).Count | Should -Be 0
        $stored['resources'].Count | Should -Be 2
        @($stored['resources'] | Where-Object { -not $_['removed'] }).Count | Should -Be 0
        $script:fixture.Calls | Should -Contain ('remove:' + $stored['ownedResourceGroups'][0]['id'])
        $script:fixture.Calls | Should -Contain ('purge:' + $script:fixture.CreatedId)
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 1
        [IO.File]::ReadAllBytes($source) | Should -Be $before
        Test-Path -LiteralPath $script:fixture.NativeInputs[0].TemplatePath | Should -BeFalse
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000099'
    }

    It 'runs assertions then the exact case hook before cleanup and reselects context between them' {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $script:options.Parameters = @{ password = ConvertTo-SecureString 'do-not-persist' -AsPlainText -Force }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $calls = @($script:fixture.Calls)
        [array]::IndexOf($calls, 'create') | Should -BeLessThan ([array]::IndexOf($calls, 'pester'))
        [array]::IndexOf($calls, 'pester') | Should -BeLessThan ([array]::IndexOf($calls, 'post'))
        [array]::IndexOf($calls, 'post') | Should -BeLessThan ([array]::IndexOf($calls, 'discover'))
        $script:fixture.PesterInput.DeploymentOutputs.account.value | Should -Be 'deployed-account'
        $script:fixture.PesterInput.ModuleTestFolderPath | Should -Be $script:fixture.Directory
        $script:fixture.HookInput.psbase.Keys.Count | Should -Be 9
        $script:fixture.HookInput.AVM_E2E_SCOPE | Should -Be 'group'
        $script:fixture.HookInput.AVM_E2E_SUBSCRIPTION_ID | Should -Be $script:options.SubscriptionId
        $result.PostResults[0].Status | Should -Be 'pass'
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw) | Should -Not -Match 'password|do-not-persist|deployed-account'
    }

    It 'never treats incomplete or failed authored suites as passed: <Mode>' -ForEach @(
        @{ Mode = 'fail' }, @{ Mode = 'skip' }, @{ Mode = 'inconclusive' },
        @{ Mode = 'filtered' }, @{ Mode = 'empty' }, @{ Mode = 'throw' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        $script:fixture.PesterMode = $Mode
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.AssertionResults[0].Status | Should -Be 'fail'
        $result.CleanupPending | Should -BeNullOrEmpty
        $result.Issues.Count | Should -BeGreaterThan 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
    }

    It 'fails a hook without suppressing ordinary cleanup: <Mode>' -ForEach @(
        @{ Mode = 'exit' }, @{ Mode = 'throw' }, @{ Mode = 'timeout' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $script:fixture.PostMode = $Mode
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.PostResults[0].Status | Should -Be 'fail'
        $result.CleanupPending | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
        if ($Mode -eq 'timeout') { ($result.Issues.Message -join ' ') | Should -Not -Match '300-second' }
    }

    It 'refuses invalid or unrelated deployment outputs, while retaining ordinary cleanup: <Mode>' -ForEach @(
        @{ Mode = 'invalid' }, @{ Mode = 'wrong-id' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        $script:fixture.OutputMode = $Mode
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $result.CleanupPending | Should -BeNullOrEmpty
    }

    It 'keeps an unclassified failure visible without replay and runs the post hook once' {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $script:fixture.CreateMode = 'failed'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -eq 'post' }).Count | Should -Be 1
        $result.CleanupPending | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).deployments.Count | Should -Be 1
    }

    It 'does not resubmit or run hooks while a timed-out submission remains unconfirmed' {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $script:fixture.CreateMode = 'timeout'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupDeferred | Should -BeTrue
        $result.CleanupPending | Should -Contain $script:fixture.LastDeploymentId
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'post'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).case.completionStarted | Should -BeFalse
    }

    It 'propagates cancellation with saved state instead of starting more work in the cancelled host' {
        $script:fixture.CreateMode = 'cancel'
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExceptionType ([OperationCanceledException])
        $state = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $state.deployments[0].status | Should -Be 'Unknown'
        $state.case.completionStarted | Should -BeFalse
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000099'
    }

    It 'cleans a newly owned group but never runs a hook after pre-submission failure: <Kind>' -ForEach @(
        @{ Kind = 'validation' }, @{ Kind = 'group creation' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $script:fixture.ValidationFails = $Kind -eq 'validation'
        $script:fixture.GroupCreateFails = $Kind -eq 'group creation'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $script:fixture.Calls | Should -Not -Contain 'create'
        $script:fixture.Calls | Should -Not -Contain 'post'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 1
        $result.CleanupPending | Should -BeNullOrEmpty
    }

    It 'reports nested Azure error codes but never Azure messages for a validation failure' {
        $script:fixture.ValidationError = [System.Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('do-not-print-secret'), 'AvmBicepTemplateValidationFailed', 'InvalidResult',
            @(@{ Code = 'InvalidTemplateDeployment'; Message = 'do-not-print-secret'
                    Details = @(@{ Code = 'AllocationFailed'; Message = 'Subscription quota exceeded. do-not-print-secret' }) }))
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $script:fixture.Calls | Should -Not -Contain 'create'
        $messages = $result.Issues.Message -join ' '
        $messages | Should -Match 'Azure error codes: InvalidTemplateDeployment, AllocationFailed\.'
        ($result | ConvertTo-Json -Depth 20) | Should -Not -Match 'do-not-print-secret'
    }

    It 'never reuses or deletes a pre-existing resource group' {
        $script:fixture.GroupExists = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $script:fixture.Calls | Should -Not -Contain 'group-create'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'retains an unverified owned group and its children instead of broad deletion' {
        $script:fixture.OwnershipMismatch = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -BeGreaterThan 0
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'stops later cases when cleanup fails and keeps its state outside temporary staging' {
        $next = Join-Path $script:fixture.Root 'tests' 'e2e' 'next'
        $null = New-Item -ItemType Directory -Path $next
        Set-Content -LiteralPath (Join-Path $next 'main.test.bicep') -Value 'param name string'
        $script:fixture.StatePath = ''
        $script:options.Remove('CleanupStatePath')
        $script:fixture.CleanupFails = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.RunsFailed | Should -Be 1
        $result.RunsSkipped | Should -Be 1
        $result.CleanupPending | Should -Contain $script:fixture.CreatedId
        $result.CleanupStatePaths.Count | Should -Be 1
        Test-Path -LiteralPath $result.CleanupStatePaths[0] | Should -BeTrue
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
    }

    It 'retains the parent group when deployment-operation discovery is incomplete' {
        $script:fixture.MissingOperations = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending | Should -Contain $script:fixture.LastDeploymentId
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'keeps the validated location and baseTime identical across deployment retries' {
        $script:fixture.RetrySequence.Enqueue('Transient')
        $script:fixture.TransientResourceType = 'Microsoft.Network/applicationGateways'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $inputs = @($script:fixture.NativeInputs)
        $inputs.Count | Should -Be 3
        @($inputs | ForEach-Object { $_.Parameters.resourceLocation } | Select-Object -Unique) | Should -Be @('eastus')
        @($inputs | ForEach-Object { $_.Parameters.baseTime } | Select-Object -Unique).Count | Should -Be 1
        @($inputs | ForEach-Object Location | Select-Object -Unique) | Should -Be @('westus')
    }

    It 'lists, ignores and previews without tool or Azure activity' {
        $names = Invoke-AvmTestE2e -Path $script:fixture.Root -List | ConvertFrom-Json
        @($names) | Should -Be @('tests/e2e/defaults')
        $null = Invoke-AvmTestE2e @script:options -WhatIf
        $script:fixture.Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:fixture.StatePath | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory '.e2eignore') -Value 'disabled'
        (Invoke-AvmTestE2e @script:options).Status | Should -Be 'skipped'
        { Invoke-AvmTestE2e @script:options -Example defaults } | Should -Throw
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'rejects missing explicit identity and unsafe group prefixes before cloud activity' {
        $script:options.Remove('TenantId')
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExpectedMessage '*TenantId*'
        $script:options.TenantId = '00000000-0000-0000-0000-000000000002'
        $script:options.ResourceGroupPrefix = 'unsafe/group'
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExpectedMessage '*ResourceGroupPrefix*'
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'never submits or allocates a group when the two sign-ins disagree' {
        $script:fixture.IdentityMismatch = $true
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExpectedMessage '*identity mismatch*'
        $script:fixture.Calls | Should -Not -Contain 'group-create'
        $script:fixture.Calls | Should -Not -Contain 'create'
        Test-Path -LiteralPath $script:fixture.StatePath | Should -BeFalse
    }
}
