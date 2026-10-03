#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native workflow recovery boundaries' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'does not rediscover a completed run after its parent group and deployment history are gone' {
        (Invoke-AvmTestE2e @script:options).Status | Should -Be 'pass'
        $script:fixture.Calls.Clear()
        $script:fixture.Deployments.Clear()
        $script:fixture.OperationMap.Clear()
        InModuleScope Avm.Authoring {
            Mock Assert-AvmBicepAzureDependency { throw 'Completed cleanup must be local.' }
            Mock Invoke-AvmBicepAzureContext { throw 'Completed cleanup must not change Azure context.' }
        }
        $result = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Cleaned | Should -BeTrue
        $result.CleanupPending.Count | Should -Be 0
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'confirms an already absent owned group during state-only recovery' {
        (Invoke-AvmTestE2e @script:options -Phase Deploy).Status | Should -Be 'pass'
        $script:fixture.Groups.Clear()
        $script:fixture.GroupAbsenceChecks = 0
        $script:fixture.Calls.Clear()
        $result = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        $script:fixture.GroupAbsenceChecks | Should -BeGreaterThan 0
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $script:fixture.Calls | Should -Not -Contain 'post'
    }

    It 'rechecks ownership before removal and purge after tags change during metadata capture' {
        $script:fixture.RetagDuringMetadata = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -match '^(remove|purge):' }).Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'CleanupPending'
    }

    It 'protects the existing management-group execution target while cleaning test resources within it' {
        $script:fixture.Schema = 'managementGroupDeploymentTemplate'
        $script:options.ManagementGroupId = 'test-management-group'
        $target = '/providers/Microsoft.Management/managementGroups/test-management-group'
        $script:fixture.AdditionalRootResources = @($target)
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending | Should -Contain $target
        $script:fixture.Calls | Should -Not -Contain ('remove:' + $target)
        $script:fixture.Calls | Should -Contain ('remove:' + $script:fixture.CreatedId)
        ($result.Issues.Message -join ' ') | Should -Match 'execution target cannot be removed'
    }

    It 'selects the recorded cross-subscription target for nested resource cleanup and restores the caller' {
        $script:fixture.Schema = 'subscriptionDeploymentTemplate'
        $script:fixture.Nested = $true
        $script:fixture.NestedSubscription = '00000000-0000-0000-0000-000000000003'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $group = ($script:fixture.CreatedId -split '/providers/', 2)[0]
        $script:fixture.RemovalSubscriptions[$group] | Should -Be $script:fixture.NestedSubscription
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000099'
    }

    It 'refuses authored script replay after <Stage> cancellation and allows cleanup-only recovery' -ForEach @(
        @{ Stage = 'assertions' }, @{ Stage = 'post' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        if ($Stage -eq 'assertions') { $script:fixture.PesterMode = 'cancel' } else { $script:fixture.PostMode = 'cancel' }
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExceptionType ([OperationCanceledException])
        @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.case.completionStarted | Should -BeTrue
        $script:fixture.Calls.Clear()
        { Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete -CleanupStatePath $script:fixture.StatePath `
                -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck } |
            Should -Throw -ExpectedMessage '*completion was interrupted*'
        $script:fixture.Calls.Count | Should -Be 0
        $result = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $script:fixture.Calls | Should -Not -Contain 'post'
    }

    It 'rejects edited case metadata before any Azure access: <Edit>' -ForEach @(
        @{ Edit = 'path' }, @{ Edit = 'scope' }, @{ Edit = 'deployment' }, @{ Edit = 'run' }
    ) {
        $null = Invoke-AvmTestE2e @script:options -Phase Deploy
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json -AsHashtable
        switch ($Edit) {
            'path' { $stored['case']['path'] = '../tests/e2e/defaults/main.test.bicep' }
            'scope' { $stored['case']['scope'] = 'tenant' }
            'deployment' { $stored['deployments'][0]['id'] += '-foreign' }
            'run' { $stored['runId'] = '0123456789abcdef0123456789abcdef' }
        }
        [IO.File]::WriteAllText($script:fixture.StatePath, ($stored | ConvertTo-Json -Depth 20))
        $script:fixture.Calls.Clear()
        { Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete -CleanupStatePath $script:fixture.StatePath `
                -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck } |
            Should -Throw
        $script:fixture.Calls.Count | Should -Be 0
    }
}
