BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
}

Describe 'Isolated candidate identity orchestration' -Tag Component {
    BeforeEach {
        $script:previousGitHubContext = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REF')) {
            $script:previousGitHubContext[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REPOSITORY_ID = '1239632211'
        $env:GITHUB_REF = 'refs/heads/main'
        $script:toolsRepository = [pscustomobject]@{
            full_name = 'Azure/azure-verified-modules-tools'
            id = 1239632211
            fork = $false
            owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
        }
        $script:repo = [pscustomobject]@{
            full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'
            name = 'terraform-azurerm-avm-ptn-example-repo'
            id = 1234
            fork = $false
            owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
        }
        $script:plan = New-AvmTestBamiPlan
        $script:identity = New-AvmTestBamiIdentity
        $script:capturedVariables = $null
        $script:parameters = @{
            RepoId = 'avm-ptn-example-repo'
            Repository = $script:repo.full_name
            BamiValues = New-AvmTestBamiSettings
            Backend = @{
                TenantId = '30000000-0000-4000-8000-000000000001'
                SubscriptionId = '30000000-0000-4000-8000-000000000002'
                ClientId = '30000000-0000-4000-8000-000000000003'
                StorageAccountName = 'tmestorage'
                ContainerName = 'tme-state'
            }
            Root = Join-Path $TestDrive 'candidate-root'
            TemporaryRoot = $TestDrive
            RepositorySyncRepositoryId = '1239632211'
            EntraGroupNames = @('avm-test-identity-owners', 'avm-test-entra-readers')
        }
        Mock Invoke-RepositoryGitHubApi {
            if ($Endpoint -ceq 'repos/Azure/azure-verified-modules-tools') { $script:toolsRepository }
            else { $script:repo }
        }
        Mock Invoke-AvmBamiIdentityTerraform {
            param($Arguments, $Root, $Environment)
            switch ($Arguments[0]) {
                'plan' {
                    $path = @($Arguments | Where-Object { $_.StartsWith('-var-file=') })[0].Substring('-var-file='.Length)
                    $script:capturedVariables = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
                }
                'show' { $script:plan | ConvertTo-Json -Depth 30 -Compress }
                'output' { @{ test_identity = @{ value = $script:identity } } | ConvertTo-Json -Depth 10 -Compress }
            }
        }
    }

    AfterEach {
        foreach ($name in $script:previousGitHubContext.Keys) {
            $value = $script:previousGitHubContext[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
        }
    }

    It 'validates all inputs before any external calls' {
        $script:parameters.BamiValues.Remove('TEST_BAMI_TENANT_ID')
        { Invoke-AvmBamiRepositoryIdentity @script:parameters } | Should -Throw
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0
    }

    It 'rejects reserved-subscription overlap before provisioning or repository reads' {
        foreach ($field in @('TEST_BAMI_ADMIN_SUBSCRIPTION_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID')) {
            $script:parameters.BamiValues = New-AvmTestBamiSettings
            $script:parameters.BamiValues.TEST_BAMI_SUBSCRIPTION_IDS[0].id = $script:parameters.BamiValues[$field]
            { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*test pool*'
        }
        $script:parameters.BamiValues = New-AvmTestBamiSettings
        $script:parameters.BamiValues.TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $script:parameters.BamiValues.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*must be different*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0
    }

    It 'plans new candidates without applying for an unknown client ID or publishing a placeholder' {
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters
        $result.Status | Should -BeExactly 'PendingCandidateIdentity'
        $result.ConsumerSettings | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'apply' }
        $script:capturedVariables.github_repository_id | Should -BeExactly '1234'
        $script:capturedVariables.github_organization_id | Should -BeExactly '6844498'
        $script:capturedVariables.repository_sync_repository_id | Should -BeExactly '1239632211'
        $script:capturedVariables.entra_group_names | Should -Be $script:parameters.EntraGroupNames
        $script:capturedVariables.Keys | Should -Not -Contain 'fabric_admin_apis'
        @(Get-ChildItem -LiteralPath $TestDrive -Directory | Where-Object Name -Like 'avm-bami-*').Count | Should -Be 0
    }

    It 'rejects an untrusted tools repository ID before planning the candidate' {
        $env:GITHUB_REPOSITORY_ID = '1234'
        { Invoke-AvmBamiRepositoryIdentity @script:parameters } | Should -Throw '*trusted tools repository*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0
    }

    It 'keeps direct BAMI candidate preparation on trusted main' {
        $env:GITHUB_REF = 'refs/heads/feature'
        { Invoke-AvmBamiRepositoryIdentity @script:parameters } | Should -Throw '*trusted*main*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0
    }

    It 'rejects a candidate whose GitHub owner differs from the trusted tools organization' {
        $script:repo.owner.id = 1234
        { Invoke-AvmBamiRepositoryIdentity @script:parameters } | Should -Throw '*unexpected candidate repository identity*'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0
    }

    It 'uses the original TME backend with a tenant-qualified key and child-only candidate provider values' {
        $previousTenant = $env:ARM_TENANT_ID
        $previousClient = $env:ARM_CLIENT_ID
        $null = Invoke-AvmBamiRepositoryIdentity @script:parameters
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'init' -and
            $Arguments -contains '-upgrade' -and
            $Arguments -contains '-backend-config=storage_account_name=tmestorage' -and
            $Arguments -contains '-backend-config=container_name=tme-state' -and
            $Arguments -contains '-backend-config=tenant_id=30000000-0000-4000-8000-000000000001' -and
            $Arguments -contains '-backend-config=subscription_id=30000000-0000-4000-8000-000000000002' -and
            $Arguments -contains '-backend-config=client_id=30000000-0000-4000-8000-000000000003' -and
            $Arguments -contains '-backend-config=key=bami-identities/10000000-0000-4000-8000-000000000001/avm-ptn-example-repo.tfstate' -and
            $Environment.ARM_TENANT_ID -eq '10000000-0000-4000-8000-000000000001' -and
            $Environment.ARM_CLIENT_ID -eq '10000000-0000-4000-8000-000000000002' -and
            $Environment.GH_TOKEN -eq $null -and $Environment.ARM_CLIENT_SECRET -eq $null
        }
        $env:ARM_TENANT_ID | Should -Be $previousTenant
        $env:ARM_CLIENT_ID | Should -Be $previousClient
    }

    It 'returns existing verified candidate outputs in plan-only without applying' {
        $script:plan = New-AvmTestBamiPlan -KnownClient
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters
        $result.Status | Should -BeExactly 'Ready'
        $result.ConsumerSettings.client_id | Should -Be '10000000-0000-4000-8000-000000000006'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'apply' }
    }

    It 'does not publish a plan-only candidate whose validation credential still needs applying' {
        $script:plan = New-AvmTestBamiPlan -KnownClient -ValidationPending
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters
        $result.Status | Should -BeExactly 'PendingCandidateIdentity'
        $result.ConsumerSettings | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'applies only the guarded saved plan and verifies dedicated outputs' {
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false
        $result.Status | Should -BeExactly 'Ready'
        $result.ConsumerSettings.test_subscription_ids.Count | Should -Be 28
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'apply' -and $Arguments[-1].EndsWith('candidate.tfplan') -and
            $Arguments -notcontains '-auto-approve'
        }
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 1 -ParameterFilter { $Arguments[0] -eq 'output' }
    }

    It 'rejects another provider identity from serialized refreshed evidence before any apply: <Field>' -ForEach @(
        @{ Address = 'module.azure.data.azapi_client_config.current'; Field = 'tenant_id'; Value = '30000000-0000-4000-8000-000000000001' }
        @{ Address = 'module.azure.data.azapi_client_config.current'; Field = 'subscription_id'; Value = '30000000-0000-4000-8000-000000000002' }
        @{ Address = 'module.azure.data.azuread_client_config.current'; Field = 'tenant_id'; Value = '30000000-0000-4000-8000-000000000001' }
        @{ Address = 'module.azure.data.azuread_client_config.current'; Field = 'client_id'; Value = '30000000-0000-4000-8000-000000000003' }
        @{ Address = 'module.azure.data.azuread_client_config.current'; Field = 'object_id'; Value = 'not-a-guid' }
    ) {
        $resource = @($script:plan.prior_state.values.root_module.child_modules[0].resources |
            Where-Object { $_['address'] -ceq $Address })[0]
        $resource.values[$Field] = $Value
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*Candidate membership requires*'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'does not apply or summarize a deferred lookup with stale refreshed evidence' {
        $resource = $script:plan.prior_state.values.root_module.child_modules[0].resources[1]
        $script:plan.resource_changes += @{
            address = $resource.address; mode = 'data'; type = $resource.type
            change = @{ actions = @('read'); before = $resource.values; after = @{}; after_unknown = $true }
        }
        Mock Write-AvmBamiIdentityPlanSummary {}
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*completed plan-time data reads*'
        Should -Invoke Write-AvmBamiIdentityPlanSummary -Exactly 0
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'refuses a wrong group binding before any candidate apply' {
        $script:plan.planned_values.root_module.child_modules[0].resources[1].values.group_object_id =
            '10000000-0000-4000-8000-000000000099'
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*resolved configured group*'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'apply' }
    }

    It 'keeps a known identity pending until required Owner membership is reconciled' {
        $script:plan = New-AvmTestBamiPlan -KnownClient
        $script:plan.resource_changes[1].change.actions = @('create')
        $script:plan.resource_changes[1].change.before = $null
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters
        $result.Status | Should -BeExactly 'PendingCandidateIdentity'
        $result.ConsumerSettings | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'passes arbitrary configured names and rejects edges outside that list' {
        $script:parameters.EntraGroupNames += 'Data engineering testers'
        $script:plan = New-AvmTestBamiPlan -KnownClient -GroupNames $script:parameters.EntraGroupNames
        (Invoke-AvmBamiRepositoryIdentity @script:parameters).Status | Should -BeExactly 'Ready'
        $script:capturedVariables.entra_group_names | Should -Be $script:parameters.EntraGroupNames
        $script:parameters.EntraGroupNames = $script:parameters.EntraGroupNames[0..1]
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*scope*'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'apply' }
    }

    It 'previews exact Owner migration and configured membership removal without applying or advertising readiness' {
        $script:plan = New-AvmTestBamiPlan -KnownClient -OwnerMigration -RemovedGroup 'former configured group'
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters
        $result.Status | Should -BeExactly 'PendingCandidateIdentity'
        $result.ConsumerSettings | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'allows only a guarded saved migration plan at the mocked apply boundary' {
        $script:plan = New-AvmTestBamiPlan -KnownClient -OwnerMigration -RemovedGroup 'former configured group'
        $result = Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false
        $result.Status | Should -BeExactly 'Ready'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 1 -ParameterFilter {
            $Arguments[0] -ceq 'apply' -and $Arguments[-1].EndsWith('candidate.tfplan')
        }
    }

    It 'fails wrong-target migration evidence before any apply' {
        $script:plan = New-AvmTestBamiPlan -KnownClient -OwnerMigration
        $script:plan.resource_changes[-1].change.before.body.properties.principalId =
            '10000000-0000-4000-8000-000000000011'
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*exact obsolete Owner assignment*'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('apply', 'output') }
    }

    It 'fails instead of repairing state, retrying an uncertain apply, or using a controller output' {
        Mock Invoke-AvmBamiIdentityTerraform { throw [System.InvalidOperationException]::new('Apply response lost; inspect retained state.') } `
            -ParameterFilter { $Arguments[0] -eq 'apply' }
        { Invoke-AvmBamiRepositoryIdentity @script:parameters -PlanOnly $false } | Should -Throw '*response lost*'
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 1 -ParameterFilter { $Arguments[0] -eq 'apply' }
        Should -Invoke Invoke-AvmBamiIdentityTerraform -Exactly 0 -ParameterFilter { $Arguments[0] -in @('state', 'import', 'force-unlock', 'output') }
    }
}
