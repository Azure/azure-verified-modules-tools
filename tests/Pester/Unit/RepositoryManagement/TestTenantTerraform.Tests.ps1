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

Describe 'Terraform selection activation' {
    It 'keeps legacy and nonactivated canaries unchanged without reading candidate fields' {
        foreach ($selection in @('legacy', 'bami')) {
            $result = Resolve-RepositoryTestTenantSettings -TestTenant $selection
            $result.TestTenant | Should -BeExactly 'legacy'
            $result.SelectedTestTenant | Should -BeExactly $selection
            $result.Settings | Should -BeNullOrEmpty
        }
        (Resolve-RepositoryTestTenantSettings -TestTenant legacy -Enabled $true -BamiValues @{ invalid = 'ignored' }).TestTenant |
            Should -BeExactly 'legacy'
    }

    It 'requires all candidate settings before activation and never chooses a partial legacy tuple' {
        { Resolve-RepositoryTestTenantSettings -TestTenant bami -Enabled $true -BamiValues @{} } | Should -Throw
        $result = Resolve-RepositoryTestTenantSettings -TestTenant bami -Enabled $true -BamiValues (New-AvmTestBamiSettings)
        $result.TestTenant | Should -BeExactly 'bami'
        $result.Settings.Count | Should -Be 8
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
    }

    It 'accepts the bounded identity plan with all three delegation deny roles' {
        { Assert-AvmBamiIdentityPlan -Plan $script:plan -Settings $script:settings -Repository $script:repository.full_name } |
            Should -Not -Throw
    }

    It 'rejects every delete or replacement, including directory membership changes' {
        foreach ($actions in @(@('delete'), @('delete', 'create'), @('create', 'delete'))) {
            $script:plan.resource_changes[2].change.actions = $actions
            { Assert-AvmBamiIdentityPlan -Plan $script:plan -Settings $script:settings -Repository $script:repository.full_name } |
                Should -Throw '*not delete or replace*'
        }
    }

    It 'rejects partial, extra or wrong-target planned resources' {
        $script:plan.planned_values.root_module.child_modules[0].resources += @{
            address = 'module.azure.azapi_resource.extra_owner'; mode = 'managed'; values = @{}
        }
        { Assert-AvmBamiIdentityPlan -Plan $script:plan -Settings $script:settings -Repository $script:repository.full_name } |
            Should -Throw '*scope*'
        $script:plan = New-AvmTestBamiPlan
        $script:plan.planned_values.root_module.child_modules[0].resources[0].values.parent_id = '/subscriptions/legacy/resourceGroups/legacy'
        { Assert-AvmBamiIdentityPlan -Plan $script:plan -Settings $script:settings -Repository $script:repository.full_name } |
            Should -Throw '*expected repository*'
        $script:plan.errored = $true
        { Assert-AvmBamiIdentityPlan -Plan $script:plan -Settings $script:settings -Repository $script:repository.full_name } |
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
                { Assert-AvmBamiIdentityPlan -Plan $invalid -Settings $script:settings -Repository $script:repository.full_name } |
                    Should -Throw '*delegation fix*'
            }
        }
        foreach ($replacement in @('GuidEquals', 'GuidNotEquals {00000000-0000-4000-8000-000000000099} OR true OR GuidNotEquals')) {
            $invalid = New-AvmTestBamiPlan
            $properties = $invalid.planned_values.root_module.child_modules[0].resources[1].values.body.properties
            $properties.condition = $properties.condition.Replace('GuidNotEquals', $replacement)
            { Assert-AvmBamiIdentityPlan -Plan $invalid -Settings $script:settings -Repository $script:repository.full_name } | Should -Throw
        }
        $invalid = New-AvmTestBamiPlan
        $properties = $invalid.planned_values.root_module.child_modules[0].resources[1].values.body.properties
        $properties.condition = $properties.condition.Replace('roleAssignments/write', 'roleAssignments/ write')
        { Assert-AvmBamiIdentityPlan -Plan $invalid -Settings $script:settings -Repository $script:repository.full_name } |
            Should -Throw '*required deny rules*'
    }

    It 'returns only a complete verified per-repository execution tuple' {
        $result = ConvertTo-AvmBamiConsumerSettings -Identity (New-AvmTestBamiIdentity) -Settings $script:settings -Repository $script:repository
        $result.client_id | Should -Be '10000000-0000-4000-8000-000000000006'
        $result.tenant_id | Should -Be $script:settings.TEST_BAMI_TENANT_ID
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

    It 'gates activation off by default before mutations and does not copy or log controller credentials' {
        $source = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1')
        $source | Should -Match '\[bool\]\$bamiTestTenantSyncEnabled = \$false'
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source.IndexOf('Invoke-AvmBamiRepositoryIdentity') | Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source | Should -Match 'if \(\$testTenant.TestTenant -ceq ''bami''\)'
        $workflow = Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'repository-management-sync.yml')
        $workflow | Should -Match 'vars.AVM_BAMI_TEST_TENANT_SYNC_ENABLED == ''true'''
        $workflow | Should -Match 'github.ref == ''refs/heads/main'''
        $workflow | Should -Not -Match 'Write-Output "Token:'
        $helper = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
        $helper | Should -Not -Match 'state (mv|rm|push|pull)|force-unlock|Import-Az|az login|Set-Az'
    }
}
