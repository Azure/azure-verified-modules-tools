#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native scoped workflow and hosted completion' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:fixture.Schema = 'subscriptionDeploymentTemplate'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'runs the full native lifecycle at <Scope> scope' -ForEach @(
        @{ Scope = 'sub'; Schema = 'subscriptionDeploymentTemplate' }
        @{ Scope = 'mg'; Schema = 'managementGroupDeploymentTemplate' }
        @{ Scope = 'tenant'; Schema = 'tenantDeploymentTemplate' }
    ) {
        $script:fixture.Schema = $Schema
        if ($Scope -eq 'mg') { $script:options.ManagementGroupId = 'test-management-group' }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $script:fixture.NativeInputs[0].Scope | Should -Be $Scope
        $script:fixture.HookInput.AVM_E2E_SCOPE | Should -Be $Scope
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
        $script:fixture.Calls | Should -Not -Contain 'group-create'
        $result.AssertionResults[0].Status | Should -Be 'pass'
        $result.PostResults[0].Status | Should -Be 'pass'
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000099'
    }

    It 'preserves an authored stable prefix and does not impose a Create-only what-if allowlist' {
        $script:options.Tokens = @{ namePrefix = 'existing-workflow-prefix' }
        $script:fixture.Resources = @(@{
                type = 'Microsoft.Resources/deployments'; name = '#_namePrefix_#'
                resourceGroup = 'authored-group'
                properties = @{ mode = 'Incremental'; template = @{ resources = @() } }
            })
        $script:fixture.Nested = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $template = $script:fixture.NativeInputs[0].Content | ConvertFrom-Json -AsHashtable
        $template.resources[0].name | Should -BeExactly 'existing-workflow-prefix'
        $template.resources[0].resourceGroup | Should -BeExactly 'authored-group'
        $nestedGroup = ($script:fixture.CreatedId -split '/providers/', 2)[0]
        $script:fixture.Calls | Should -Contain ('remove:' + $nestedGroup)
        $script:fixture.Calls | Should -Contain ('purge:' + $script:fixture.CreatedId)
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 1
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.resources.Count | Should -Be 2
        @($stored.resources | Where-Object { -not $_.removed -or -not $_.postProcessed }).Count | Should -Be 0
    }

    It 'supports caller-owned sign-in renewal without recompiling, resubmitting or persisting outputs' {
        $deployment = Invoke-AvmTestE2e @script:options -Phase Deploy
        $deployment.Status | Should -Be 'pass'
        $deployment.CleanupDeferred | Should -BeTrue
        $deployment.AssertionResults.Count | Should -Be 0
        $deployment.PostResults.Count | Should -Be 0
        $script:fixture.Calls | Should -Not -Contain 'pester'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw
        $stored | Should -Not -Match 'deployed-account|DeploymentOutputs|parameters|Outputs'
        ($stored | ConvertFrom-Json).case.completionStarted | Should -BeFalse
        $script:fixture.Calls.Clear()
        $script:fixture.CurrentSubscription = '00000000-0000-0000-0000-000000000097'
        $completed = Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete `
            -CleanupStatePath $script:fixture.StatePath -SubscriptionId $script:options.SubscriptionId `
            -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $completed.Status | Should -Be 'pass'
        $completed.CleanupDeferred | Should -BeFalse
        $script:fixture.Calls | Should -Not -Contain 'compile'
        $script:fixture.Calls | Should -Not -Contain 'create'
        $script:fixture.Calls | Should -Contain 'outputs'
        $script:fixture.Calls | Should -Contain 'pester'
        $script:fixture.Calls | Should -Contain 'post'
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000097'
        { Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete `
                -CleanupStatePath $script:fixture.StatePath -SubscriptionId $script:options.SubscriptionId `
                -TenantId $script:options.TenantId -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*already completed*'
    }

    It 'completes failed deployment cleanup after renewal without treating failure as a green case' {
        $script:fixture.CreateMode = 'failed'
        $deployment = Invoke-AvmTestE2e @script:options -Phase Deploy -DeploymentRetryLimit 1
        $deployment.Status | Should -Be 'fail'
        $deployment.CleanupDeferred | Should -BeTrue
        $script:fixture.Calls.Clear()
        $completed = Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete `
            -CleanupStatePath $script:fixture.StatePath -SubscriptionId $script:options.SubscriptionId `
            -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $completed.Status | Should -Be 'fail'
        $completed.CleanupPending.Count | Should -Be 0
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $script:fixture.Calls | Should -Contain 'post'
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
    }

    It 'rejects changed source or a mismatched explicit identity before completion: <Change>' -ForEach @(
        @{ Change = 'source' }, @{ Change = 'subscription' }, @{ Change = 'tenant' }
    ) {
        $null = Invoke-AvmTestE2e @script:options -Phase Deploy
        $script:fixture.Calls.Clear()
        $completion = @{
            Path = $script:fixture.Root; Phase = 'Complete'; CleanupStatePath = $script:fixture.StatePath
            SubscriptionId = $script:options.SubscriptionId; TenantId = $script:options.TenantId
            SkipModuleVersionCheck = $true
        }
        if ($Change -eq 'source') {
            Add-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'Write-Output changed'
        }
        elseif ($Change -eq 'subscription') { $completion.SubscriptionId = '00000000-0000-0000-0000-000000000003' }
        else { $completion.TenantId = '00000000-0000-0000-0000-000000000004' }
        { Invoke-AvmTestE2e @completion } | Should -Throw
        $script:fixture.Calls.Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).case.completionStarted | Should -BeFalse
    }

    It 'permits explicit retention for debugging and cleanup-only recovery without authored scripts' {
        $result = Invoke-AvmTestE2e @script:options -KeepResources
        $result.Status | Should -Be 'pass'
        $result.CleanupDeferred | Should -BeTrue
        $script:fixture.Calls | Should -Contain 'pester'
        $script:fixture.Calls | Should -Not -Contain 'post'
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        $script:fixture.Calls.Clear()
        $cleanup = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $cleanup.Status | Should -Be 'pass'
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $script:fixture.Calls | Should -Not -Contain 'post'
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
    }

    It 'does not overwrite an existing state file before submitting anything' {
        Set-Content -LiteralPath $script:fixture.StatePath -Value 'existing caller content'
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExpectedMessage '*overwrite*'
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw).Trim() | Should -BeExactly 'existing caller content'
        $script:fixture.Calls | Should -Not -Contain 'create'
    }

    It 'does not assume tenant-root permission when validation is denied' {
        $script:fixture.Schema = 'tenantDeploymentTemplate'
        $script:fixture.ValidationFails = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $script:fixture.Calls | Should -Not -Contain 'create'
        $script:fixture.Calls | Should -Not -Contain 'post'
        $result.CleanupPending.Count | Should -Be 0
    }

    It 'watches a timed-out submission to a late success without resubmitting it' {
        $script:fixture.CreateMode = 'timeout'
        $script:fixture.ReadinessState = 'Succeeded'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        $script:fixture.Calls | Should -Contain 'pester'
        $script:fixture.Calls | Should -Contain 'post'
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
    }

    It 'fails and cleans a timed-out submission that later fails like any confirmed failure' {
        $script:fixture.CreateMode = 'timeout'
        $script:fixture.ReadinessState = 'Failed'
        $result = Invoke-AvmTestE2e @script:options -DeploymentRetryLimit 1
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
    }

    It 'removes a wholly regional failure and its record before relocating to an unused region' {
        $script:options.Remove('ResourceLocation')
        $script:fixture.RegionalFailures = 1
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create' | ForEach-Object { $_.Parameters['resourceLocation'] }) |
            Should -Be @('eastus', 'centralus')
        $deleted = @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' })
        $deleted.Count | Should -Be 1
        $script:fixture.Calls.IndexOf($deleted[0]) | Should -BeLessThan ($script:fixture.Calls.LastIndexOf('create'))
        $script:fixture.Calls | Should -Contain 'pester'
    }

    It 'stops relocation but still runs ordinary cleanup when a regional failure record cannot be removed' {
        $script:options.Remove('ResourceLocation')
        $script:fixture.RegionalFailures = 1
        $script:fixture.RecordDeleteFails = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.Calls | Where-Object { $_ -eq 'create' }).Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'pester'
        @($result.Issues | ForEach-Object Code) | Should -Contain 'avm.bicep.e2e-relocation-blocked'
        @($result.Issues | Where-Object Message -like '*ended with*outcome*').Count | Should -Be 0
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
    }

    It 'retries a regional failure in place when the region is pinned' {
        $script:fixture.RegionalFailures = 1
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create' | ForEach-Object { $_.Parameters['resourceLocation'] }) |
            Should -Be @('eastus', 'eastus')
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }
}
