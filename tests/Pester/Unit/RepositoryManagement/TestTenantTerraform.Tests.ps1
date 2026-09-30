BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    $script:repository = [pscustomobject]@{
        full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'
        name = 'terraform-azurerm-avm-ptn-example-repo'
        id = 1234
        fork = $false
        owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
    }
}

Describe 'Tools repository federation context' {
    BeforeEach {
        $script:previousGitHubContext = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID')) {
            $script:previousGitHubContext[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REPOSITORY_ID = '1239632211'
        $script:toolsRepository = [pscustomobject]@{
            full_name = 'Azure/azure-verified-modules-tools'
            id = 1239632211
            fork = $false
            owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
        }
        Mock Invoke-RepositoryGitHubApi { $script:toolsRepository }
    }

    AfterEach {
        foreach ($name in $script:previousGitHubContext.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:previousGitHubContext[$name])
        }
    }

    It 'confirms the runner repository ID against the GitHub repository record' {
        $context = Resolve-AvmRepositorySyncFederationContext -RepositoryId $env:GITHUB_REPOSITORY_ID
        $context.RepositoryId | Should -BeExactly '1239632211'
        $context.OrganizationId | Should -BeExactly '6844498'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 1 -ParameterFilter {
            $Endpoint -ceq 'repos/Azure/azure-verified-modules-tools'
        }
    }

    It 'rejects untrusted runner context: <Case>' -ForEach @(
        @{ Case = 'not Actions'; Actions = ''; Repository = 'Azure/azure-verified-modules-tools'; Id = '1239632211'; Supplied = '1239632211' }
        @{ Case = 'fork'; Actions = 'true'; Repository = 'fork/azure-verified-modules-tools'; Id = '1239632211'; Supplied = '1239632211' }
        @{ Case = 'missing repository'; Actions = 'true'; Repository = ''; Id = '1239632211'; Supplied = '1239632211' }
        @{ Case = 'missing ID'; Actions = 'true'; Repository = 'Azure/azure-verified-modules-tools'; Id = ''; Supplied = '' }
        @{ Case = 'zero ID'; Actions = 'true'; Repository = 'Azure/azure-verified-modules-tools'; Id = '0'; Supplied = '0' }
        @{ Case = 'leading zero'; Actions = 'true'; Repository = 'Azure/azure-verified-modules-tools'; Id = '0123'; Supplied = '0123' }
        @{ Case = 'nonnumeric ID'; Actions = 'true'; Repository = 'Azure/azure-verified-modules-tools'; Id = '123abc'; Supplied = '123abc' }
        @{ Case = 'swapped input'; Actions = 'true'; Repository = 'Azure/azure-verified-modules-tools'; Id = '1239632211'; Supplied = '987654321' }
    ) {
        param($Case, $Actions, $Repository, $Id, $Supplied)
        $env:GITHUB_ACTIONS = $Actions
        $env:GITHUB_REPOSITORY = $Repository
        $env:GITHUB_REPOSITORY_ID = $Id
        { Resolve-AvmRepositorySyncFederationContext -RepositoryId $Supplied } |
            Should -Throw '*trusted tools repository*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
    }

    It 'rejects mismatched or forked GitHub repository records' {
        foreach ($change in @('id', 'name', 'fork', 'owner', 'ownerId')) {
            $script:toolsRepository = [pscustomobject]@{
                full_name = 'Azure/azure-verified-modules-tools'
                id = 1239632211
                fork = $false
                owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
            }
            switch ($change) {
                'id' { $script:toolsRepository.id = 1234 }
                'name' { $script:toolsRepository.full_name = 'fork/azure-verified-modules-tools' }
                'fork' { $script:toolsRepository.fork = $true }
                'owner' { $script:toolsRepository.owner.login = 'Other' }
                'ownerId' { $script:toolsRepository.owner.id = 0 }
            }
            { Resolve-AvmRepositorySyncFederationContext -RepositoryId $env:GITHUB_REPOSITORY_ID } |
                Should -Throw '*GitHub did not confirm*'
        }
    }
}

Describe 'Terraform test tenant selection' {
    It 'keeps explicitly legacy selections on their normal path without candidate dependencies' {
        $result = Resolve-RepositoryTestTenantSettings -TestTenant legacy
        $result.TestTenant | Should -BeExactly 'legacy'
        $result.Status | Should -BeExactly 'Ready'
        $result.Settings | Should -BeNullOrEmpty
        (Resolve-RepositoryTestTenantSettings -TestTenant legacy -BamiValues @{ invalid = 'ignored' }).TestTenant |
            Should -BeExactly 'legacy'
    }

    It 'resolves selected BAMI settings without a separate activation parameter' {
        $result = Resolve-RepositoryTestTenantSettings -TestTenant bami -BamiValues (New-AvmTestBamiSettings)
        $result.TestTenant | Should -BeExactly 'bami'
        $result.SelectedTestTenant | Should -BeExactly 'bami'
        $result.Status | Should -BeExactly 'Ready'
        $result.Settings.Count | Should -Be 8
        $result.Settings.TEST_BAMI_TENANT_ID | Should -BeExactly '10000000-0000-4000-8000-000000000001'
        (Get-Command Resolve-RepositoryTestTenantSettings).Parameters.ContainsKey('Enabled') | Should -BeFalse
    }

    It 'requires the complete selected bundle and rejects invalid selections instead of falling back to legacy' {
        { Resolve-RepositoryTestTenantSettings -TestTenant bami } | Should -Throw '*complete BAMI bundle*'
        foreach ($value in @('BAMI', 'future', $true, 1)) {
            { Resolve-RepositoryTestTenantSettings -TestTenant $value } | Should -Throw '*exactly*'
        }
    }

    It 'separates the state key by tenant and repository without changing the legacy key' {
        Get-AvmBamiIdentityStateKey -TenantId '10000000-0000-4000-8000-000000000001' -RepoId avm-ptn-example-repo |
            Should -BeExactly 'bami-identities/10000000-0000-4000-8000-000000000001/avm-ptn-example-repo.tfstate'
        Get-AvmBamiIdentityStateKey -TenantId '20000000-0000-4000-8000-000000000001' -RepoId avm-ptn-example-repo |
            Should -BeExactly 'bami-identities/20000000-0000-4000-8000-000000000001/avm-ptn-example-repo.tfstate'
        foreach ($repoId in @('../legacy', 'avm-ptn-example/other', 'AVM-ptn-example', 'example')) {
            { Get-AvmBamiIdentityStateKey -TenantId '10000000-0000-4000-8000-000000000001' -RepoId $repoId } | Should -Throw
        }
    }
}

Describe 'Candidate plan and output safety' {
    BeforeEach {
        $script:settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $script:plan = New-AvmTestBamiPlan
        $script:planArguments = @{
            Settings = $script:settings
            Repository = $script:repository.full_name
            RepositoryOwnerId = '6844498'
            RepositorySyncRepositoryId = '1239632211'
        }
    }

    It 'accepts the bounded identity plan with all three delegation deny roles' {
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Not -Throw
    }

    It 'requires exactly the tools validation credential alongside the existing three environment credentials' {
        $addresses = @($script:plan.planned_values.root_module.child_modules[0].resources | ForEach-Object { $_.address })
        @($addresses | Where-Object { $_ -like '*federated_credential*' }).Count | Should -Be 4
        $addresses | Should -Contain 'module.azure.azapi_resource.validation_federated_credential'
        $script:plan.planned_values.root_module.child_modules[0].resources =
            @($script:plan.planned_values.root_module.child_modules[0].resources | Where-Object {
                    $_.address -cne 'module.azure.azapi_resource.validation_federated_credential'
                })
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Throw '*scope*'
    }

    It 'rejects changed validation federation claims, identity scope, or audiences' {
        $mutations = @(
            @{ field = 'subject'; value = 'repository_owner_id:6844498:repository_id:1234:environment:avm-validation' }
            @{ field = 'subject'; value = 'repository_owner_id:6844498:repository_id:1239632211:ref:refs/heads/main' }
            @{ field = 'subject'; value = 'repository_owner_id:6844498:repository_id:1239632211:environment:avm-validation:job_workflow_ref:untrusted' }
            @{ field = 'issuer'; value = 'https://example.invalid' }
            @{ field = 'audiences'; value = @('api://AzureADTokenExchange', 'untrusted') }
            @{ field = 'name'; value = 'another-identity-avm-validation' }
            @{ field = 'type'; value = 'Microsoft.Authorization/roleAssignments@2022-04-01' }
            @{ field = 'parent_id'; value = '/subscriptions/another/resourceGroups/another/providers/Microsoft.ManagedIdentity/userAssignedIdentities/another' }
        )
        foreach ($mutation in $mutations) {
            $invalid = New-AvmTestBamiPlan -KnownClient
            $credential = @($invalid.planned_values.root_module.child_modules[0].resources | Where-Object {
                    $_.address -ceq 'module.azure.azapi_resource.validation_federated_credential'
                })[0].values
            if ($mutation.field -in @('subject', 'issuer', 'audiences')) {
                $credential.body.properties[$mutation.field] = $mutation.value
            }
            else {
                $credential[$mutation.field] = $mutation.value
            }
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } |
                Should -Throw '*validation federation*'
        }
    }

    It 'binds the BAMI validation subject to the supplied verified IDs' {
        $alternate = New-AvmTestBamiPlan -RepositorySyncRepositoryId '987654321'
        $script:planArguments.RepositorySyncRepositoryId = '987654321'
        { Assert-AvmBamiIdentityPlan -Plan $alternate @script:planArguments } | Should -Not -Throw
        $script:planArguments.RepositorySyncRepositoryId = '1239632211'
        { Assert-AvmBamiIdentityPlan -Plan $alternate @script:planArguments } | Should -Throw '*validation federation*'

        $alternate = New-AvmTestBamiPlan -RepositoryOwnerId '123456789'
        $script:planArguments.RepositoryOwnerId = '123456789'
        { Assert-AvmBamiIdentityPlan -Plan $alternate @script:planArguments } | Should -Not -Throw
        $script:planArguments.RepositoryOwnerId = '6844498'
        { Assert-AvmBamiIdentityPlan -Plan $alternate @script:planArguments } | Should -Throw '*validation federation*'
    }

    It 'rejects every delete or replacement, including directory membership changes' {
        foreach ($actions in @(@('delete'), @('delete', 'create'), @('create', 'delete'))) {
            $script:plan.resource_changes[2].change.actions = $actions
            { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
                Should -Throw '*not delete or replace*'
        }
    }

    It 'rejects partial, extra or wrong-target planned resources' {
        $script:plan.planned_values.root_module.child_modules[0].resources += @{
            address = 'module.azure.azapi_resource.extra_owner'; mode = 'managed'; values = @{}
        }
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Throw '*scope*'
        $script:plan = New-AvmTestBamiPlan
        $script:plan.planned_values.root_module.child_modules[0].resources[0].values.parent_id = '/subscriptions/legacy/resourceGroups/legacy'
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Throw '*expected repository*'
        $script:plan.errored = $true
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Throw '*incomplete or errored*'
    }

    It 'requires Owner, UAA and RBAC Administrator in both clauses, with the correct semantics' {
        foreach ($role in @('8e3af657-a8ff-443c-a75c-2fe8c4bcb635', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')) {
            foreach ($clause in @(0, 1)) {
                $invalid = New-AvmTestBamiPlan
                $properties = $invalid.planned_values.root_module.child_modules[0].resources[1].values.body.properties
                $parts = $properties.condition -split '\r?\nAND\r?\n'
                $parts[$clause] = $parts[$clause].Replace($role, '00000000-0000-4000-8000-000000000099')
                $properties.condition = $parts -join "`nAND`n"
                { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } |
                    Should -Throw '*delegation fix*'
            }
        }
        foreach ($replacement in @('GuidEquals', 'GuidNotEquals {00000000-0000-4000-8000-000000000099} OR true OR GuidNotEquals')) {
            $invalid = New-AvmTestBamiPlan
            $properties = $invalid.planned_values.root_module.child_modules[0].resources[1].values.body.properties
            $properties.condition = $properties.condition.Replace('GuidNotEquals', $replacement)
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw
        }
        $invalid = New-AvmTestBamiPlan
        $properties = $invalid.planned_values.root_module.child_modules[0].resources[1].values.body.properties
        $properties.condition = $properties.condition.Replace('roleAssignments/write', 'roleAssignments/ write')
        { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } |
            Should -Throw '*required deny rules*'
    }

    It 'returns only a complete verified per-repository execution tuple' {
        $result = ConvertTo-AvmBamiConsumerSettings -Identity (New-AvmTestBamiIdentity) -Settings $script:settings -Repository $script:repository
        $result.client_id | Should -Be '10000000-0000-4000-8000-000000000006'
        $result.tenant_id | Should -Be $script:settings.TEST_BAMI_TENANT_ID
        $result.admin_subscription_id | Should -Be $script:settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID
        $result.persistent_subscription_id | Should -Be $script:settings.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        $result.test_subscription_ids.Count | Should -Be 28
        foreach ($client in @($script:settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $script:settings.TEST_BAMI_BICEP_CLIENT_ID, [guid]::Empty.ToString())) {
            $identity = New-AvmTestBamiIdentity
            $identity.client_id = $client
            { ConvertTo-AvmBamiConsumerSettings -Identity $identity -Settings $script:settings -Repository $script:repository } |
                Should -Throw '*dedicated test identity*'
        }
        foreach ($field in @('tenant_id', 'repository_id', 'repository_owner_id', 'identity_resource_id')) {
            $identity = New-AvmTestBamiIdentity
            $identity[$field] = 'wrong'
            { ConvertTo-AvmBamiConsumerSettings -Identity $identity -Settings $script:settings -Repository $script:repository } |
                Should -Throw '*dedicated test identity*'
        }
    }

    It 'revalidates reserved subscriptions before constructing the internal root override' {
        $invalid = New-AvmTestBamiSettings
        $invalid.TEST_BAMI_SUBSCRIPTION_IDS[0].id = $invalid.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        { ConvertTo-AvmBamiConsumerSettings -Identity (New-AvmTestBamiIdentity) -Settings $invalid -Repository $script:repository } |
            Should -Throw '*Persistent*test pool*'
    }
}

Describe 'Terraform effective contract and state wiring' {
    It 'continues writing repository secrets that actually override legacy variables' {
        $secrets = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'modules' 'github' 'github.actions_secrets.tf')
        foreach ($name in @('ARM_TENANT_ID', 'ARM_CLIENT_ID', 'TEST_SUBSCRIPTION_IDS')) {
            $secrets | Should -Match ('secret_name\s*=\s*"' + $name + '"')
        }
        ([regex]::Matches($secrets, 'resource "github_actions_secret"')).Count | Should -Be 3
        $workflow = Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'terraform-module.yml')
        $merge = [regex]::Match($workflow, '(?s)\$combined = @\{\}\s+foreach \(\$k in \$varsMap.Keys\) \{.*?\}\s+foreach \(\$k in \$secretsMap.Keys\) \{.*?\}')
        $merge.Success | Should -BeTrue
        $varsMap = @{ ARM_TENANT_ID = 'legacy'; ARM_CLIENT_ID = 'legacy'; TEST_SUBSCRIPTION_IDS = 'legacy' }
        $secretsMap = @{ ARM_TENANT_ID = 'candidate'; ARM_CLIENT_ID = 'dedicated-repo'; TEST_SUBSCRIPTION_IDS = 'candidate-pool' }
        $merged = & ([scriptblock]::Create($merge.Value + "`nreturn `$combined"))
        foreach ($name in $secretsMap.Keys) { $merged[$name] | Should -Be $secretsMap[$name] }
        $workflow | Should -Match 'TEST_SUBSCRIPTION_IDS: \$\{\{ secrets.TEST_SUBSCRIPTION_IDS \}\}'
    }

    It 'keeps legacy Azure resource addresses, provider inputs and backend independent' {
        $main = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'main.tf')
        $legacy = [regex]::Match($main, '(?s)^module "azure" \{.*?\n\}').Value
        $legacy | Should -Not -BeNullOrEmpty
        $legacy | Should -Match 'count\s*=\s*var.repository_creation_mode_enabled \? 0 : 1'
        $legacy | Should -Not -Match 'bami|test_settings'
        $legacy | Should -Match 'identity_resource_group_name\s*=\s*var.identity_resource_group_name'
        $main | Should -Match 'arm_client_id\s*=\s*local.test_settings.client_id'
        $main | Should -Match 'arm_tenant_id\s*=\s*local.test_settings.tenant_id'
        $main | Should -Match 'test_subscription_ids\s*=\s*local.test_settings.test_subscription_ids'
        $candidate = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'bami-identity' 'terraform.tf')
        $candidate | Should -Match 'backend "azurerm" \{\}'
        $candidate | Should -Not -Match 'provider "github"|storage_account_name\s*='
        ([regex]::Matches($candidate, 'client_id\s*=\s*var.controller_client_id')).Count | Should -Be 2
        ([regex]::Matches($candidate, 'use_cli\s*=\s*false')).Count | Should -Be 2
    }

    It 'uses the existing per-module identity for both validation subjects without changing the original trust' {
        $azure = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure' 'main.tf')
        $original = [regex]::Match($azure, '(?sm)^resource "azapi_resource" "identity_federated_credentials" \{.*?^\}').Value
        $original | Should -Match 'for_each\s*=\s*var.github_repository_environment_names'
        $original | Should -Match 'subject\s*=\s*"repository_owner_id:\$\{var.github_organization_id\}:repository_id:\$\{var.github_repository_id\}:environment:\$\{each.value\}:job_workflow_ref:\$\{var.github_job_workflow_ref\}"'
        $validation = [regex]::Match($azure, '(?sm)^resource "azapi_resource" "validation_federated_credential" \{.*?^\}').Value
        $validation | Should -Not -BeNullOrEmpty
        $validation | Should -Match 'parent_id\s*=\s*azapi_resource.identity.id'
        $validation | Should -Match 'locks\s*=\s*\[azapi_resource.identity.id\]'
        $validation | Should -Match 'name\s*=\s*"\$\{local.owner_repo_name\}-avm-validation"'
        $validation | Should -Match 'subject\s*=\s*"repository_owner_id:\$\{var.github_organization_id\}:repository_id:\$\{var.repository_sync_repository_id\}:environment:avm-validation"'
        $validation | Should -Not -Match 'repository_owner_id:[0-9]|repository_id:[0-9]'
        $validation | Should -Not -Match 'job_workflow_ref:|ref:refs/heads/'
        $ordinary = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'main.tf')
        $bami = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'bami-identity' 'main.tf')
        $ordinary | Should -Match 'source\s*=\s*"\./modules/azure"'
        $bami | Should -Match 'source\s*=\s*"\.\./terraform/modules/azure"'
        $ordinary | Should -Match 'repository_sync_repository_id\s*=\s*var.repository_sync_repository_id'
        $bami | Should -Match 'repository_sync_repository_id\s*=\s*var.repository_sync_repository_id'
        $ordinary | Should -Match 'count\s*=\s*var.repository_creation_mode_enabled \? 0 : 1'
        $bami | Should -Not -Match 'resource\s+"azapi_resource"\s+"identity"'
    }

    It 'exposes the effective legacy or BAMI test settings to plan-only consumers' {
        $output = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'outputs.tf')
        $output | Should -Match '(?s)output "test_settings" \{\s*description\s*=\s*"[^"]+"\s*value\s*=\s*local.test_settings\s*\}'
        $locals = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'locals.tf')
        $locals | Should -Match 'client_id\s*=\s*module.azure\[0\].client_id'
        $locals | Should -Match 'tenant_id\s*=\s*module.azure\[0\].tenant_id'
        $locals | Should -Match 'test_subscription_ids\s*=\s*var.test_subscription_ids'
        foreach ($field in @('tenant_id', 'client_id', 'test_subscription_ids')) {
            $locals | Should -Match ('\b' + $field + '\s*=\s*var.bami_test_settings\.' + $field + '\b')
        }
        $settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $subscriptions = ConvertFrom-AvmTestTenantJson -Json $settings.TEST_BAMI_SUBSCRIPTION_IDS
        $subscriptions.Count | Should -Be 28
        $subscriptions.id | Should -Not -Contain $settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID
        $subscriptions.id | Should -Not -Contain $settings.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
    }

    It 'validates selected settings and the trusted BAMI run context before mutations without an activation switch' {
        $source = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1')
        $source | Should -Not -Match 'bamiTestTenantSyncEnabled|PendingTestTenantActivation'
        $source | Should -Match 'Assert-AvmBamiRepositorySyncRunContext -PlanOnly \$planOnly'
        $source.IndexOf('Assert-AvmBamiRepositorySyncRunContext') | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeGreaterThan 0
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $source.IndexOf('Resolve-AvmRepositorySyncFederationContext') | Should -BeGreaterThan $source.IndexOf('Resolve-RepositoryTestTenantSettings')
        $source.IndexOf('Resolve-AvmRepositorySyncFederationContext') | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source.IndexOf('Invoke-AvmBamiRepositoryIdentity') | Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source | Should -Match 'if \(\$testTenant.TestTenant -ceq ''bami''\)'
        $workflow = Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'repository-management-sync.yml')
        $workflow | Should -Match '-bamiSettings \$bamiSettings'
        $source | Should -Match '\[string\]\$repositorySyncRepositoryId = \$env:GITHUB_REPOSITORY_ID'
        $workflow | Should -Not -Match '-repositorySyncRepositoryId'
        $workflow | Should -Not -Match 'AVM_BAMI_TEST_TENANT_SYNC_ENABLED|bamiTestTenantSyncEnabled'
        $workflow | Should -Not -Match 'Write-Output "Token:'
        $helper = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
        $helper | Should -Match 'Assert-AvmBamiRepositorySyncRunContext -PlanOnly \$PlanOnly'
        $helper | Should -Match '\$env:GITHUB_ACTIONS -cne ''true'''
        $helper | Should -Match '\$env:GITHUB_REPOSITORY -cne ''Azure/azure-verified-modules-tools'''
        $helper | Should -Match '\$env:GITHUB_EVENT_NAME -ceq ''workflow_dispatch'''
        $helper | Should -Match '\$env:GITHUB_REF -cne ''refs/heads/main'''
        $helper | Should -Not -Match 'state (mv|rm|push|pull)|force-unlock|Import-Az|az login|Set-Az'
    }
}
