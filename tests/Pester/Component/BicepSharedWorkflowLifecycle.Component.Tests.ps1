#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
    . (Join-Path $repoRoot 'scripts' 'bicep-workflows' 'Validation.ps1')
    $script:savedEnvironment = @{}
    foreach ($name in @('GITHUB_STEP_SUMMARY', 'AVM_CI_VARIABLES', 'AVM_CI_SECRETS', 'TOKEN_NAMEPREFIX', 'CI_KEY_VAULT_NAME')) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [NullString]::Value)
    }
    function Get-AzContext { [CmdletBinding()] param() throw 'Azure context inspection must be mocked.' }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:savedEnvironment.Keys) {
        $value = $script:savedEnvironment[$name]
        [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
    }
}

Describe 'Component: Bicep shared workflow native lifecycle' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:fixture.Schema = 'subscriptionDeploymentTemplate'
        $options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:parameters = @{
            Root = Split-Path -Parent $script:fixture.Root
            ModulePath = Split-Path -Leaf $script:fixture.Root
            SubscriptionId = $options.SubscriptionId; TenantId = $options.TenantId
            ClientId = '00000000-0000-4000-8000-000000000003'
            StatePath = $script:fixture.StatePath
            ResultDirectory = Join-Path $script:fixture.Root 'results'
        }
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        Mock Get-AzContext {
            [pscustomobject]@{
                Subscription = @{ Id = $script:parameters.SubscriptionId }
                Tenant = @{ Id = $script:parameters.TenantId }
                Account = @{ Id = $script:parameters.ClientId; Type = 'ServicePrincipal' }
                Environment = @{ Name = 'AzureCloud' }
            }
        }
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'completes exhausted deployment once, retaining failure and cleaning every attempt after the final post' {
        $script:fixture.CreateMode = 'failed'
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' -Confirm:$false } |
            Should -Throw '*did not pass*'
        $deployed = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $deployed.deployments.Count | Should -Be 3
        @($deployed.deployments | Where-Object status -NE 'Failed').Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -match '^(post|pester|remove:|purge:|delete-record:)' }).Count | Should -Be 0
        $createdByAttempt = @(foreach ($deployment in $deployed.deployments) {
                $resourceId = $script:fixture.CreatedId + '-' + $deployment.id.Split('-')[-1]
                $script:fixture.OperationMap[$deployment.id][0].properties.targetResource.id = $resourceId
                $resourceId
            })

        { Invoke-AvmWorkflowE2e @script:parameters -Phase Complete -Confirm:$false } | Should -Throw '*did not pass*'
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 3
        @($script:fixture.Calls | Where-Object { $_ -eq 'post' }).Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $postIndex = $script:fixture.Calls.IndexOf('post')
        $postIndex | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        foreach ($call in $script:fixture.Calls | Where-Object { $_ -match '^(remove:|purge:|delete-record:)' }) {
            $script:fixture.Calls.IndexOf($call) | Should -BeGreaterThan $postIndex
        }
        foreach ($resourceId in $createdByAttempt) {
            $script:fixture.Calls | Should -Contain "remove:$resourceId"
        }
        $script:fixture.HookInput.AVM_E2E_DEPLOYMENT_NAME | Should -BeExactly $deployed.deployments[-1].id.Split('/')[-1]
        $completed = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $completed.status | Should -Be 'Complete'
        $completed.deployments.Count | Should -Be 3
        @($completed.resources | Where-Object { $_.id -in $createdByAttempt -and $_.removed }).Count | Should -Be 3
        foreach ($phase in @('deploy', 'complete')) {
            (Get-Content -LiteralPath (Join-Path $script:parameters.ResultDirectory "$phase.json") -Raw | ConvertFrom-Json).Status |
                Should -Be 'fail'
        }

        $callCount = $script:fixture.Calls.Count
        Invoke-AvmWorkflowRecovery -StatePath $script:fixture.StatePath -SubscriptionId $script:parameters.SubscriptionId `
            -TenantId $script:parameters.TenantId -ClientId $script:parameters.ClientId -Confirm:$false
        $script:fixture.Calls.Count | Should -Be $callCount
    }

    It 'keeps failed deployments when resource removal is disabled, without post or cleanup' {
        $script:fixture.CreateMode = 'failed'
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' `
                -RemoveDeployment $false -Confirm:$false } | Should -Throw '*did not pass*'
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Complete -RemoveDeployment $false -Confirm:$false } |
            Should -Throw '*did not pass*'
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 3
        @($script:fixture.Calls | Where-Object { $_ -match '^(post|pester|remove:|purge:|delete-record:)' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Not -Be 'Complete'
        $stored.case.completionStarted | Should -BeTrue
    }

    It 'retains cancelled deployment state without starting final post or deletion' {
        $script:fixture.CreateMode = 'cancel'
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' -Confirm:$false } |
            Should -Throw -ExceptionType ([OperationCanceledException])
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -match '^(post|pester|remove:|purge:|delete-record:)' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Not -Be 'Complete'
        $stored.case.completionStarted | Should -BeFalse
    }

    It 'retains cancellation during completion and permits only later cleanup without replaying the post hook' {
        $script:fixture.PostMode = 'cancel'
        Invoke-AvmWorkflowE2e @script:parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' -Confirm:$false
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Complete -Confirm:$false } |
            Should -Throw -ExceptionType ([OperationCanceledException])
        @($script:fixture.Calls | Where-Object { $_ -match '^(remove:|purge:|delete-record:)' }).Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).case.completionStarted | Should -BeTrue

        $script:fixture.Calls.Clear()
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Complete -Confirm:$false } | Should -Throw '*completion was interrupted*'
        $script:fixture.Calls.Count | Should -Be 0
        Invoke-AvmWorkflowRecovery -StatePath $script:fixture.StatePath -SubscriptionId $script:parameters.SubscriptionId `
            -TenantId $script:parameters.TenantId -ClientId $script:parameters.ClientId -Confirm:$false
        @($script:fixture.Calls | Where-Object { $_ -match '^(post|pester|create)$' }).Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
    }

    It 'never executes authored completion for <Change> after a terminal failure' -ForEach @(
        @{ Change = 'changed source'; Recoverable = $true }
        @{ Change = 'interrupted completion'; Recoverable = $true }
        @{ Change = 'invalid state'; Recoverable = $false }
        @{ Change = 'foreign deployment'; Recoverable = $false }
        @{ Change = 'missing state'; Recoverable = $false }
    ) {
        $script:fixture.CreateMode = 'failed'
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' -Confirm:$false } |
            Should -Throw '*did not pass*'
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json -AsHashtable
        switch ($Change) {
            'changed source' { Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 1' }
            'interrupted completion' {
                $stored['case']['completionStarted'] = $true
                [IO.File]::WriteAllText($script:fixture.StatePath, ($stored | ConvertTo-Json -Depth 30))
            }
            'invalid state' { [IO.File]::WriteAllText($script:fixture.StatePath, '{') }
            'foreign deployment' {
                $stored['deployments'][0]['id'] += '-foreign'
                [IO.File]::WriteAllText($script:fixture.StatePath, ($stored | ConvertTo-Json -Depth 30))
            }
            'missing state' { Remove-Item -LiteralPath $script:fixture.StatePath -Force }
        }
        $script:fixture.Calls.Clear()
        { Invoke-AvmWorkflowE2e @script:parameters -Phase Complete -Confirm:$false } | Should -Throw
        $script:fixture.Calls.Count | Should -Be 0
        $recovery = @{
            StatePath = $script:fixture.StatePath; SubscriptionId = $script:parameters.SubscriptionId
            TenantId = $script:parameters.TenantId; ClientId = $script:parameters.ClientId
        }
        if ($Recoverable) {
            Invoke-AvmWorkflowRecovery @recovery -Confirm:$false
            (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
        }
        elseif ($Change -eq 'missing state') {
            Invoke-AvmWorkflowRecovery @recovery -Confirm:$false
            $script:fixture.Calls.Count | Should -Be 0
        }
        else {
            { Invoke-AvmWorkflowRecovery @recovery -Confirm:$false } | Should -Throw
            $script:fixture.Calls.Count | Should -Be 0
        }
        @($script:fixture.Calls | Where-Object { $_ -match '^(post|pester|create)$' }).Count | Should -Be 0
    }
}
