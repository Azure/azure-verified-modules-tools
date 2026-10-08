#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
}

Describe 'Component: Bicep native management-group authorization recovery' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:fixture.Schema = 'managementGroupDeploymentTemplate'
        $script:fixture.CreateMode = 'forbidden'
        $script:fixture.ReadinessState = 'Succeeded'
        $script:options.ManagementGroupId = 'test-management-group'
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'recovers exact outputs for assertions and cleans normally without replay' {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 1
        $reads = @($script:fixture.RestInputs | Where-Object { $null -ne $_.DefaultProfile })
        $reads.Count | Should -Be 1
        $reads[0].Method | Should -Be 'GET'
        $reads[0].Path | Should -BeExactly "$($script:fixture.LastDeploymentId)?api-version=2021-04-01"
        [object]::ReferenceEquals($reads[0].DefaultProfile, $creates[0].DefaultProfile) | Should -BeTrue
        $script:fixture.PesterInput.DeploymentOutputs.account.value | Should -BeExactly 'deployed-account'
        $script:fixture.Calls | Should -Contain 'pester'
        $script:fixture.Calls | Should -Contain 'post'
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'Complete'
        $stored.deployments.Count | Should -Be 1
        $stored.deployments[0].status | Should -Be 'Succeeded'
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000099'
    }

    It 'does not run assertions or spend another deployment on <Recovery>' -ForEach @(
        @{ Recovery = 'Failed'; State = 'Failed'; OutputMode = 'valid' }
        @{ Recovery = 'Unknown'; State = 'Unknown'; OutputMode = 'valid' }
        @{ Recovery = 'Canceled'; State = 'Canceled'; OutputMode = 'valid' }
        @{ Recovery = 'wrong ID'; State = 'Succeeded'; OutputMode = 'wrong-id' }
        @{ Recovery = 'invalid outputs'; State = 'Succeeded'; OutputMode = 'invalid' }
    ) {
        $script:fixture.ReadinessState = $State
        $script:fixture.OutputMode = $OutputMode
        $result = Invoke-AvmTestE2e @script:options -Phase Deploy
        $result.Status | Should -Be 'fail'
        $result.CleanupDeferred | Should -BeTrue
        ($result.Issues.Message -join ' ') | Should -Match 'HTTP 403'
        ($result.Issues.Message -join ' ') | Should -Not -Match 'private-fixture-detail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'discover'
        $script:fixture.Calls | Should -Not -Contain 'pester'
        @($script:fixture.Calls | Where-Object { $_ -match '^(delete-record|remove|purge):' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments.Count | Should -Be 1
        $stored.deployments[0].preflightRejected | Should -BeFalse
    }

    It 'does not treat validation-stage HTTP 403 as a submitted deployment' {
        $script:fixture.ValidationError = [Net.Http.HttpRequestException]::new(
            'Validation forbidden.', $null, [Net.HttpStatusCode]::Forbidden)
        $result = Invoke-AvmTestE2e @script:options -Phase Deploy
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 0
        $script:fixture.RestInputs.Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).deployments.Count | Should -Be 0
    }
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native cleaned retries' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:options.Remove('ResourceLocation')
        $script:fixture.Schema = 'subscriptionDeploymentTemplate'
        $script:fixture.TransientResourceType = 'Microsoft.Network/privateEndpoints'
        $script:fixture.RetrySequence.Enqueue('Transient')
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'cleans before replaying the same validated region after <Response> evidence' -ForEach @(
        @{ Response = 'returned failure'; Throws = $false }, @{ Response = 'submission exception'; Throws = $true }
    ) {
        $script:fixture.ThrowRetryFailure = $Throws
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 2
        $creates.Parameters.resourceLocation | Should -Be @('eastus', 'eastus')
        $creates[0].Parameters.baseTime | Should -BeExactly $creates[1].Parameters.baseTime
        $creates[0].Content | Should -BeExactly $creates[1].Content
        $creates.Location | Should -Be @('westus', 'westus')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        $deleted = @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' })
        $deleted.Count | Should -Be 1
        $script:fixture.Calls.IndexOf("purge:$($script:fixture.CreatedId)") | Should -BeLessThan $script:fixture.Calls.IndexOf($deleted[0])
        $script:fixture.Calls.IndexOf($deleted[0]) | Should -BeLessThan $script:fixture.Calls.LastIndexOf('create')
    }

    It 'shares the submission budget across <Order> retries while revalidating only changed regions' -ForEach @(
        @{ Order = 'regional then transient'; Sequence = @('Regional', 'Transient'); Regions = @('eastus', 'centralus', 'centralus') }
        @{ Order = 'transient then regional'; Sequence = @('Transient', 'Regional'); Regions = @('eastus', 'eastus', 'centralus') }
    ) {
        $script:fixture.RetrySequence.Clear()
        foreach ($kind in $Sequence) { $script:fixture.RetrySequence.Enqueue($kind) }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 3
        $creates.Parameters.resourceLocation | Should -Be $Regions
        @($creates.Parameters.baseTime | Sort-Object -Unique).Count | Should -Be 1
        @($creates.Location | Sort-Object -Unique) | Should -Be @('westus')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 2
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments[0].id | Should -BeLike '*-t3'
    }

    It 'stops at the original submission budget even when all failures are transient' {
        $script:fixture.RetrySequence.Enqueue('Transient')
        $script:fixture.RetrySequence.Enqueue('Transient')
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 3
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 2
        $script:fixture.Calls | Should -Not -Contain 'pester'
    }

    It 'does not enable cleaned replay for <Restriction>' -ForEach @(
        @{ Restriction = 'pinned region' }, @{ Restriction = 'global placement' }
        @{ Restriction = 'resource-group scope' }, @{ Restriction = 'retained resources' }
    ) {
        switch ($Restriction) {
            'pinned region' { $script:options.ResourceLocation = 'eastus' }
            'global placement' {
                Mock Get-AvmBicepResourceLocation -ModuleName Avm.Authoring {
                    [pscustomobject]@{ Location = 'global'; IsGlobal = $true }
                }
            }
            'resource-group scope' { $script:fixture.Schema = 'deploymentTemplate' }
            'retained resources' { $script:options.KeepResources = $true }
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        if ($Restriction -eq 'retained resources') {
            @($script:fixture.Calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
        }
    }

    It 'blocks same-region replay when deployment scripts may still be cleaning up' {
        $scriptId = "/subscriptions/$($script:options.SubscriptionId)/resourceGroups/scripts/providers/Microsoft.Resources/deploymentScripts/script"
        $script:fixture.AdditionalRootResources = @($scriptId)
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        $script:fixture.Calls | Should -Contain "remove:$scriptId"
        $result.Issues.Code | Should -Contain 'avm.bicep.e2e-relocation-blocked'
    }

    It 'does not resubmit an unknown failure without eligible structured evidence' {
        $script:fixture.ThrowRetryFailure = $true
        $script:fixture.TransientErrorCode = 'AuthorizationFailed'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }

    It 'finds deployment scripts in nested operation histories before allowing cleaned replay' {
        Mock Write-AvmLog -ModuleName Avm.Authoring {}
        $script:fixture.Nested = $true
        $script:fixture.NestedExtensions = @('Microsoft.Resources/deploymentScripts/script')
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        Should -Invoke Write-AvmLog -ModuleName Avm.Authoring -Times 1 -ParameterFilter {
            $Message -like '*contains deployment scripts*'
        }
    }

    It 'does not fall back to in-place replay after an unreadable operation history' {
        $script:fixture.OperationLookupDenied = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        $result.CleanupPending.Count | Should -BeGreaterThan 0
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }

    It 'does not recover a malformed returned <Response> into a retry' -ForEach @(
        @{ Response = 'array-id' }, @{ Response = 'array-state' }
    ) {
        $script:fixture.NativeResponseMode = $Response
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }

    It 'retains pending history deletion for cleanup-only recovery after <Obstacle>' -ForEach @(
        @{ Obstacle = 'delayed visibility' }, @{ Obstacle = 'Deleting' }, @{ Obstacle = 'authorization failure' }
    ) {
        if ($Obstacle -in @('delayed visibility', 'Deleting')) { $script:fixture.RecordVisibilityReads = 6 }
        else { $script:fixture.RecordConfirmationDenied = $true }
        if ($Obstacle -eq 'Deleting') { $script:fixture.RecordVisibilityState = 'Deleting' }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 1
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'CleanupPending'
        $stored.deployments[0].recordDeletion | Should -Be 'Pending'
        $result.CleanupPending | Should -Contain $stored.deployments[0].id
        $script:fixture.RecordConfirmationDenied = $false
        $script:fixture.Calls.Clear()
        $cleanup = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $cleanup.Status | Should -Be 'pass'
        $cleanup.CleanupPending.Count | Should -Be 0
        $script:fixture.Calls | Should -Not -Contain 'discover'
        $script:fixture.Calls | Should -Not -Contain 'create'
        @($script:fixture.Calls | Where-Object { $_ -match '^(delete-record|remove|purge):' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'Complete'
        $stored.deployments[0].recordDeletion | Should -Be 'Complete'
    }

    It 'finishes accepted <State> history during final cleanup without retrying the deployment' -ForEach @(
        @{ State = 'Failed' }, @{ State = 'Deleting' }
    ) {
        $script:fixture.RecordVisibilityReads = 3
        $script:fixture.RecordVisibilityState = $State
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 1
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'Complete'
        $stored.deployments[0].recordDeletion | Should -Be 'Complete'
    }

    It 'waits for Deleting history to disappear before replaying the validated region' {
        $script:fixture.RecordVisibilityReads = 2
        $script:fixture.RecordVisibilityState = 'Deleting'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 2
        $creates.Parameters.resourceLocation | Should -Be @('eastus', 'eastus')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        $deleted = @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' })
        $deleted.Count | Should -Be 1
        $confirmations = @($script:fixture.Calls | Where-Object { $_ -like 'confirm-record:*' })
        $confirmations.Count | Should -Be 3
        $script:fixture.Calls.LastIndexOf($confirmations[-1]) | Should -BeLessThan $script:fixture.Calls.LastIndexOf('create')
    }

    It 'persists independent progress when only some failed root records have disappeared' {
        $script:fixture.RetrySequence.Clear()
        $script:fixture.RetrySequence.Enqueue('Unclassified')
        $script:fixture.RetrySequence.Enqueue('Transient')
        $script:fixture.FailuresRemaining = 1
        $script:fixture.RecordVisibilityReads = 6
        $script:fixture.RecordVisibilityAfterDeletion = 2
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 2
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments.Count | Should -Be 2
        @($stored.deployments.recordDeletion | Sort-Object) | Should -Be @('Complete', 'Pending')
        $result.CleanupPending.Count | Should -Be 1
        $script:fixture.Calls.Clear()
        $cleanup = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $cleanup.Status | Should -Be 'pass'
        $script:fixture.Calls | Should -Not -Contain 'discover'
        @($script:fixture.Calls | Where-Object { $_ -match '^(delete-record|remove|purge):' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments.recordDeletion | Should -Be @('Complete', 'Complete')
    }
}
