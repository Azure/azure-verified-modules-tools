#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')

    function Invoke-NativeHistoryCleanup {
        param($Fixture, $Options)
        InModuleScope Avm.Authoring -Parameters @{
            StatePath = $Fixture.StatePath; Subscription = $Options.SubscriptionId; Tenant = $Options.TenantId
        } {
            param($StatePath, $Subscription, $Tenant)
            Invoke-AvmBicepCleanup -StatePath $StatePath -SubscriptionId $Subscription -TenantId $Tenant -RequireCompleteRemoval
        }
    }
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

Describe 'Component: Bicep native attempt contexts and finalization' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:options.Remove('ResourceLocation')
        $script:fixture.Schema = 'subscriptionDeploymentTemplate'
        $script:fixture.TransientResourceType = 'Microsoft.Network/privateEndpoints'
        $script:fixture.UseGeneratedNames = $true
        $script:fixture.RetrySequence.Enqueue('Regional')
        $script:fixture.Parameters['generatedName'] = @{ type = 'string' }
        $script:fixture.Parameters['runName'] = @{ type = 'string' }
        $script:options.Parameters = @{ generatedName = '#_namePrefix_#'; runName = '#_avmE2eRunId_#' }
    }
    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'executes configured <Mode>/<Placement> semantics at <Scope> scope' -ForEach @(
        @{ Mode = 'InPlace'; Placement = 'NextEligible'; Scope = 'sub' }
        @{ Mode = 'InPlace'; Placement = 'NextEligible'; Scope = 'group' }
        @{ Mode = 'Fresh'; Placement = 'NextEligible'; Scope = 'sub' }
        @{ Mode = 'Fresh'; Placement = 'NextEligible'; Scope = 'group' }
        @{ Mode = 'Fresh'; Placement = 'Preserve'; Scope = 'sub' }
        @{ Mode = 'Fresh'; Placement = 'Preserve'; Scope = 'group' }
        @{ Mode = 'Fresh'; Placement = 'NextEligible'; Scope = 'mg' }
        @{ Mode = 'Fresh'; Placement = 'NextEligible'; Scope = 'tenant' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mode = $Mode; Placement = $Placement } {
            param($Mode, $Placement)
            $policy = Get-AvmBicepRetryPolicy
            ($policy['rules'] | Where-Object { $_['id'] -eq 'allocation-capacity' })['mode'] = $Mode
            $policy['modes']['Fresh']['location'] = $Placement
            $script:contextRetryPolicy = Get-AvmBicepRetryPolicy -InputObject $policy
            Mock Get-AvmBicepRetryPolicy { $script:contextRetryPolicy }
        }
        if ($Scope -eq 'group') { $script:fixture.Schema = 'deploymentTemplate' }
        if ($Scope -eq 'mg') {
            $script:fixture.Schema = 'managementGroupDeploymentTemplate'
            $script:options.ManagementGroupId = 'retry-test-group'
        }
        if ($Scope -eq 'tenant') { $script:fixture.Schema = 'tenantDeploymentTemplate' }
        if ($Placement -eq 'Preserve') { $script:options.ResourceLocation = 'eastus' }
        $before = Get-Content -LiteralPath (Join-Path $script:fixture.Directory 'main.test.bicep') -Raw
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending | Should -BeNullOrEmpty
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 2
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.attempts.mode | Should -Be @('Initial', $Mode)
        $stored.status | Should -Be 'Complete'
        if ($Mode -eq 'InPlace') {
            $creates[1].DeploymentName | Should -BeExactly $creates[0].DeploymentName
            $creates[1].Content | Should -BeExactly $creates[0].Content
            ($creates[1].Parameters | ConvertTo-Json -Depth 20 -Compress) |
                Should -BeExactly ($creates[0].Parameters | ConvertTo-Json -Depth 20 -Compress)
            $stored.attempts[1].namingId | Should -BeExactly $stored.attempts[0].namingId
            $stored.deployments.Count | Should -Be 1
        }
        else {
            $creates[1].DeploymentName | Should -Not -Be $creates[0].DeploymentName
            $creates[1].Parameters.generatedName | Should -Not -Be $creates[0].Parameters.generatedName
            $creates[1].Parameters.runName | Should -Not -Be $creates[0].Parameters.runName
            $stored.attempts[1].namingId | Should -Not -Be $stored.attempts[0].namingId
            $stored.deployments.Count | Should -Be 2
            foreach ($index in 0, 1) {
                $creates[$index].Parameters.runName | Should -BeExactly $stored.attempts[$index].namingId
                ($creates[$index].Content | ConvertFrom-Json).resources[0].name |
                    Should -BeExactly $creates[$index].Parameters.generatedName
            }
            if ($Scope -eq 'group') {
                $creates[1].ResourceGroupName | Should -Not -Be $creates[0].ResourceGroupName
                $stored.ownedResourceGroups.Count | Should -Be 2
            }
        }
        $expectedRegions = if ($Mode -eq 'Fresh' -and $Placement -eq 'NextEligible') { @('eastus', 'centralus') }
        else { @('eastus', 'eastus') }
        $creates.Parameters.resourceLocation | Should -Be $expectedRegions
        @($creates.Parameters.baseTime | Sort-Object -Unique).Count | Should -Be 1
        @($creates.Location | Sort-Object -Unique) | Should -Be @('westus')
        @($script:fixture.Calls | Where-Object { $_ -eq 'compile' }).Count | Should -Be 1
        foreach ($call in @($script:fixture.Calls | Where-Object { $_ -match '^(remove|purge):' })) {
            $script:fixture.Calls.IndexOf($call) | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        }
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:fixture.Directory 'main.test.bicep') -Raw) | Should -BeExactly $before
    }

    It 'preserves <FixedNames> rather than pretending Bicep-authored or caller names are isolated' -ForEach @(
        @{ FixedNames = 'Bicep-authored names' }, @{ FixedNames = 'explicit caller prefix' }
    ) {
        if ($FixedNames -eq 'Bicep-authored names') { $script:fixture.Resources[0].name = 'fixed-inside-bicep' }
        else { $script:options.Tokens = @{ namePrefix = 'fixed-caller-prefix' } }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 2
        $creates[1].DeploymentName | Should -Not -Be $creates[0].DeploymentName
        $creates[1].Parameters.runName | Should -Not -Be $creates[0].Parameters.runName
        ($creates[1].Content | ConvertFrom-Json).resources[0].name |
            Should -BeExactly ($creates[0].Content | ConvertFrom-Json).resources[0].name
        @($script:fixture.CreatedIds | Select-Object -Unique).Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -eq "remove:$($script:fixture.CreatedId)" }).Count | Should -Be 1
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).resources.Count | Should -Be 1
    }

    It 'retains resources missing from overwritten operation history through <Mode> retries' -ForEach @(
        @{ Mode = 'InPlace' }, @{ Mode = 'Fresh' }
    ) {
        $script:fixture.Nested = $true
        if ($Mode -eq 'InPlace') {
            $script:fixture.RetrySequence.Clear()
            $script:fixture.RetrySequence.Enqueue('Transient')
        }

        $earlierId = "/subscriptions/$($script:options.SubscriptionId)/resourceGroups/first-attempt/providers/Microsoft.Storage/storageAccounts/earlier"
        $script:fixture.FirstAttemptResources = @($earlierId)
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending | Should -BeNullOrEmpty
        $script:fixture.Calls | Should -Contain "remove:$earlierId"
        $script:fixture.Calls.IndexOf("remove:$earlierId") | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        $finalHistory = $script:fixture.OperationMap | ConvertTo-Json -Depth 20
        $finalHistory | Should -Not -Match ([regex]::Escape($earlierId))
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        ($stored.resources | Where-Object id -eq $earlierId).removed | Should -BeTrue
        ($stored.resources | Where-Object id -eq $earlierId).postProcessed | Should -BeTrue
    }

    It 'rejects ambiguous attempt-group <Field> before submission' -ForEach @(
        @{ Field = 'identity' }, @{ Field = 'ownership' }, @{ Field = 'response' }
    ) {
        $script:fixture.Schema = 'deploymentTemplate'
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field; Subscription = $script:options.SubscriptionId } {
            param($Field, $Subscription)
            Mock New-AzResourceGroup {
                $response = @{ ResourceId = "/subscriptions/$Subscription/resourceGroups/$Name"; Tags = $Tag.Clone() }
                switch ($Field) {
                    'identity' { $response.ResourceId = @($response.ResourceId) }
                    'ownership' {
                        $ownerTag = (Get-AvmBicepConfiguration)['e2e']['ownershipTag']
                        $response.Tags[$ownerTag] = @($response.Tags[$ownerTag])
                    }
                    'response' { return , @($response) }
                }
                $response
            }
        }
        (Invoke-AvmTestE2e @script:options -Phase Deploy).Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.ownedResourceGroups.Count | Should -Be 1
        $stored.attempts.Count | Should -Be 0
    }

    It 'deduplicates differently cased resource identities across attempts before final removal' {
        $resourceId = "/subscriptions/$($script:options.SubscriptionId)/resourceGroups/shared-test/providers/Microsoft.Storage/storageAccounts/shared"
        $script:fixture.AdditionalRootResources = @($resourceId)
        $script:fixture.FirstAttemptResources = @($resourceId.ToUpperInvariant())
        (Invoke-AvmTestE2e @script:options).Status | Should -Be 'pass'
        @($script:fixture.Calls | Where-Object { $_ -ieq "remove:$resourceId" }).Count | Should -Be 1
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        @($stored.resources | Where-Object id -IEQ $resourceId).Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }

    It 'cleans every submitted attempt after <Outcome>' -ForEach @(
        @{ Outcome = 'success'; Expected = 'pass'; Attempts = 2 }
        @{ Outcome = 'unclassified failure'; Expected = 'fail'; Attempts = 2 }
        @{ Outcome = 'exhaustion'; Expected = 'fail'; Attempts = 3 }
    ) {
        if ($Outcome -eq 'unclassified failure') { $script:fixture.CreateMode = 'failed' }
        if ($Outcome -eq 'exhaustion') {
            $script:fixture.RetrySequence.Enqueue('Regional')
            $script:fixture.RetrySequence.Enqueue('Regional')
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be $Expected
        $result.CleanupPending | Should -BeNullOrEmpty
        @($script:fixture.CreatedIds | Select-Object -Unique).Count | Should -Be $Attempts
        foreach ($id in $script:fixture.CreatedIds) {
            @($script:fixture.Calls | Where-Object { $_ -eq "remove:$id" }).Count | Should -Be 1
            $script:fixture.Calls.IndexOf("remove:$id") | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        }
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
    }

    It 'honors lower configured deployment and region budgets with the configured delay' {
        InModuleScope Avm.Authoring {
            $policy = Get-AvmBicepRetryPolicy
            $policy['limits'] = @{ deploymentAttempts = 2; regionAttempts = 2; delaySeconds = 7 }
            $script:contextRetryPolicy = Get-AvmBicepRetryPolicy -InputObject $policy
            Mock Get-AvmBicepRetryPolicy { $script:contextRetryPolicy }
        }
        $script:fixture.RetrySequence.Enqueue('Regional')
        $script:fixture.RetrySequence.Enqueue('Regional')
        $result = Invoke-AvmTestE2e @script:options -DeploymentRetryLimit 3 -ValidationRetryLimit 3
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 2
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 2
        InModuleScope Avm.Authoring { Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 7 } }
        $result.CleanupPending | Should -BeNullOrEmpty
    }

    It 'preserves all attempt evidence after cancellation and later cleans without resubmission' {
        $script:fixture.CancelAtAttempt = 2
        { Invoke-AvmTestE2e @script:options } | Should -Throw -ExceptionType ([OperationCanceledException])
        @($script:fixture.Calls | Where-Object { $_ -match '^(remove|purge|delete-record):' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.attempts.Count | Should -Be 2
        $stored.deployments[-1].status | Should -Be 'Unknown'
        $stored.resources.id | Should -Contain $script:fixture.CreatedIds[0]
        $stored.case.completionStarted | Should -BeFalse
        $script:fixture.Calls.Clear()
        $result = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        foreach ($id in $script:fixture.CreatedIds) { $script:fixture.Calls | Should -Contain "remove:$id" }
        $script:fixture.Calls | Should -Not -Contain 'create'
        $script:fixture.Calls | Should -Not -Contain 'pester'
        $script:fixture.Calls | Should -Not -Contain 'post'
    }

    It 'keeps submission and region budgets independent for <Mode>/<Placement>/<Regions>' -ForEach @(
        @{ Mode = 'InPlace'; Placement = 'NextEligible'; Regions = 1; Submissions = 3; Expected = 3 }
        @{ Mode = 'Fresh'; Placement = 'NextEligible'; Regions = 2; Submissions = 3; Expected = 2 }
        @{ Mode = 'Fresh'; Placement = 'NextEligible'; Regions = 3; Submissions = 2; Expected = 2 }
        @{ Mode = 'Fresh'; Placement = 'Preserve'; Regions = 1; Submissions = 3; Expected = 3 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{
            Mode = $Mode; Placement = $Placement; Regions = $Regions; Submissions = $Submissions
        } {
            param($Mode, $Placement, $Regions, $Submissions)
            $policy = Get-AvmBicepRetryPolicy
            ($policy['rules'] | Where-Object { $_['id'] -eq 'allocation-capacity' })['mode'] = $Mode
            $policy['modes']['Fresh']['location'] = $Placement
            $policy['limits']['deploymentAttempts'] = $Submissions
            $policy['limits']['regionAttempts'] = $Regions
            $script:contextRetryPolicy = Get-AvmBicepRetryPolicy -InputObject $policy
            Mock Get-AvmBicepRetryPolicy { $script:contextRetryPolicy }
        }
        $script:fixture.RetrySequence.Enqueue('Regional')
        $script:fixture.RetrySequence.Enqueue('Regional')
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending | Should -BeNullOrEmpty
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be $Expected
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
    }

    It 'defers all attempt deletion for <Lifecycle> and then cleans without compiling again' -ForEach @(
        @{ Lifecycle = 'Deploy/Complete' }, @{ Lifecycle = 'KeepResources/cleanup' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'post.ps1') -Value 'exit 0'
        $phaseOptions = if ($Lifecycle -eq 'Deploy/Complete') { @{ Phase = 'Deploy' } } else { @{ KeepResources = $true } }
        $result = Invoke-AvmTestE2e @script:options @phaseOptions
        $result.Status | Should -Be 'pass'
        $result.CleanupDeferred | Should -BeTrue
        @($script:fixture.Calls | Where-Object { $_ -match '^(remove|purge|delete-record):' }).Count | Should -Be 0
        $script:fixture.Calls | Should -Not -Contain 'post'
        if ($Lifecycle -eq 'KeepResources/cleanup') { $script:fixture.Calls | Should -Contain 'pester' }
        $script:fixture.Calls.Clear()
        if ($Lifecycle -eq 'Deploy/Complete') {
            $result = Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete -CleanupStatePath $script:fixture.StatePath `
                -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
            $script:fixture.Calls | Should -Contain 'pester'
            $script:fixture.Calls | Should -Contain 'post'
        }
        else {
            $result = Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
                -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
            $script:fixture.Calls | Should -Not -Contain 'pester'
            $script:fixture.Calls | Should -Not -Contain 'post'
        }
        $result.Status | Should -Be 'pass'
        foreach ($id in $script:fixture.CreatedIds) { $script:fixture.Calls | Should -Contain "remove:$id" }
        $script:fixture.Calls | Should -Not -Contain 'create'
        $script:fixture.Calls | Should -Not -Contain 'compile'
    }

    It 'rejects altered attempt journals before Azure access: <Change>' -ForEach @(
        @{ Change = 'ordering' }, @{ Change = 'duplicate fresh root' }, @{ Change = 'duplicate naming context' }
        @{ Change = 'foreign subscription' }, @{ Change = 'unknown property' }, @{ Change = 'changed in-place context' }
        @{ Change = 'uncovered root' }, @{ Change = 'array naming ID' }, @{ Change = 'missing case' }
    ) {
        (Invoke-AvmTestE2e @script:options -Phase Deploy).Status | Should -Be 'pass'
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json -AsHashtable
        switch ($Change) {
            'ordering' { $stored.attempts[1].number = 3 }
            'duplicate fresh root' { $stored.attempts[1].deploymentId = $stored.attempts[0].deploymentId }
            'duplicate naming context' { $stored.attempts[1].namingId = $stored.attempts[0].namingId }
            'foreign subscription' { $stored.attempts[1].deploymentId = $stored.attempts[1].deploymentId.Replace($stored.subscriptionId, '00000000-0000-0000-0000-000000000003') }
            'unknown property' { $stored.attempts[1]['parameters'] = @{ secret = 'not-allowed' } }
            'changed in-place context' { $stored.attempts[1].mode = 'InPlace' }
            'uncovered root' { $stored.attempts = @($stored.attempts[0]) }
            'array naming ID' { $stored.attempts[1].namingId = @($stored.attempts[1].namingId) }
            'missing case' { $stored.Remove('case') }
        }
        [IO.File]::WriteAllText($script:fixture.StatePath, ($stored | ConvertTo-Json -Depth 30))
        $script:fixture.Calls.Clear()
        { Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
                -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck } |
            Should -Throw
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'continues to read and clean a legacy single-context state without an attempt journal' {
        $script:fixture.RetrySequence.Clear()
        (Invoke-AvmTestE2e @script:options -Phase Deploy).Status | Should -Be 'pass'
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json -AsHashtable
        $stored.Remove('attempts')
        [IO.File]::WriteAllText($script:fixture.StatePath, ($stored | ConvertTo-Json -Depth 30))
        $script:fixture.Calls.Clear()
        (Invoke-AvmTestCleanup -StatePath $script:fixture.StatePath `
                -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck).Status | Should -Be 'pass'
        $script:fixture.Calls | Should -Contain "remove:$($script:fixture.CreatedId)"
        $script:fixture.Calls | Should -Not -Contain 'create'
    }

    It 'never replays a <Response> with structured authorization evidence even beside capacity errors' -ForEach @(
        @{ Response = 'returned failure'; Throws = $false }, @{ Response = 'thrown failure'; Throws = $true }
    ) {
        $script:fixture.ThrowRetryFailure = $Throws
        $script:fixture.RegionalErrorFactory = {
            @{
                code = 'InvalidTemplateDeployment'
                message = "The template deployment failed with error: 'Authorization failed for template resource.'"
                details = @(@{ code = 'AllocationFailed'; message = 'Insufficient capacity in the region.' })
            }
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        $result.CleanupPending | Should -BeNullOrEmpty
        $script:fixture.Calls | Should -Contain "remove:$($script:fixture.CreatedId)"
    }
}

Describe 'Component: Bicep native policy retries and retained history recovery' -Tag Component {
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

    It 'reuses the deployment and inputs without deletion between attempts after <Response> evidence' -ForEach @(
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
        $creates[0].DeploymentName | Should -BeExactly $creates[1].DeploymentName
        $creates.Location | Should -Be @('westus', 'westus')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        $deleted = @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' })
        $deleted.Count | Should -Be 0
        $script:fixture.Calls.IndexOf("remove:$($script:fixture.CreatedId)") | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        $script:fixture.Calls.IndexOf("purge:$($script:fixture.CreatedId)") | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments.Count | Should -Be 1
        $stored.attempts.mode | Should -Be @('Initial', 'InPlace')
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
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments.Count | Should -Be 2
        $stored.attempts.Count | Should -Be 3
        @($stored.attempts.namingId | Select-Object -Unique).Count | Should -Be 2
        $stored.attempts.mode | Should -Contain 'InPlace'
        $stored.attempts.mode | Should -Contain 'Fresh'
    }

    It 'stops at the original submission budget even when all failures are transient' {
        $script:fixture.RetrySequence.Enqueue('Transient')
        $script:fixture.RetrySequence.Enqueue('Transient')
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 3
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        @($script:fixture.NativeInputs.DeploymentName | Select-Object -Unique).Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'pester'
    }

    It 'permits an in-place policy without changing <Restriction>' -ForEach @(
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

    It 'retains deployment scripts until the final in-place attempt finishes' {
        $scriptId = "/subscriptions/$($script:options.SubscriptionId)/resourceGroups/scripts/providers/Microsoft.Resources/deploymentScripts/script"
        $script:fixture.AdditionalRootResources = @($scriptId)
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        $script:fixture.Calls | Should -Contain "remove:$scriptId"
        $script:fixture.Calls.IndexOf("remove:$scriptId") | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
        $result.Issues.Count | Should -Be 0
    }

    It 'does not resubmit an unknown failure without eligible structured evidence' {
        $script:fixture.ThrowRetryFailure = $true
        $script:fixture.TransientErrorCode = 'AuthorizationFailed'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }

    It 'preserves nested deployment scripts without deleting them between attempts' {
        Mock Write-AvmLog -ModuleName Avm.Authoring {}
        $script:fixture.Nested = $true
        $script:fixture.NestedExtensions = @('Microsoft.Resources/deploymentScripts/script')
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $scripts = @($stored.resources | Where-Object type -eq 'Microsoft.Resources/deploymentScripts')
        $scripts.Count | Should -Be 1
        $scripts[0].postProcessed | Should -BeTrue
        $purge = 'purge:' + $scripts[0].id
        $script:fixture.Calls.IndexOf($purge) | Should -BeGreaterThan $script:fixture.Calls.LastIndexOf('create')
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
        $deployment = Invoke-AvmTestE2e @script:options -Phase Deploy -DeploymentRetryLimit 1
        $deployment.Status | Should -Be 'fail'
        $result = Invoke-NativeHistoryCleanup -Fixture $script:fixture -Options $script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 1
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'CleanupPending'
        $stored.deployments[0].recordDeletion | Should -Be 'Pending'
        $result.Pending | Should -Contain $stored.deployments[0].id
        $script:fixture.RecordConfirmationDenied = $false
        $script:fixture.RecordVisibilityReads = 0
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

    It 'finishes accepted <State> history during explicit cleanup without retrying the deployment' -ForEach @(
        @{ State = 'Failed' }, @{ State = 'Deleting' }
    ) {
        $script:fixture.RecordVisibilityReads = 2
        $script:fixture.RecordVisibilityState = $State
        $deployment = Invoke-AvmTestE2e @script:options -Phase Deploy -DeploymentRetryLimit 1
        $deployment.Status | Should -Be 'fail'
        $result = Invoke-NativeHistoryCleanup -Fixture $script:fixture -Options $script:options
        $result.Status | Should -Be 'pass'
        $result.Pending.Count | Should -Be 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 1
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.status | Should -Be 'Complete'
        $stored.deployments[0].recordDeletion | Should -Be 'Complete'
    }

    It 'never starts deployment-record deletion while reusing the validated deployment' {
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
        $deleted.Count | Should -Be 0
        $confirmations = @($script:fixture.Calls | Where-Object { $_ -like 'confirm-record:*' })
        $confirmations.Count | Should -Be 0
        $creates[0].DeploymentName | Should -BeExactly $creates[1].DeploymentName
    }

    It 'persists independent progress when only some failed root records have disappeared' {
        $script:fixture.RetrySequence.Clear()
        $script:fixture.RetrySequence.Enqueue('Regional')
        $script:fixture.RetrySequence.Enqueue('Regional')
        $script:fixture.RecordVisibilityReads = 6
        $script:fixture.RecordVisibilityAfterDeletion = 2
        $deployment = Invoke-AvmTestE2e @script:options -Phase Deploy -DeploymentRetryLimit 2
        $deployment.Status | Should -Be 'fail'
        $result = Invoke-NativeHistoryCleanup -Fixture $script:fixture -Options $script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 2
        $stored = Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json
        $stored.deployments.Count | Should -Be 2
        @($stored.deployments.recordDeletion | Sort-Object) | Should -Be @('Complete', 'Pending')
        $result.Pending.Count | Should -Be 1
        $script:fixture.RecordVisibilityReads = 0
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
