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
            $value = $script:previousGitHubContext[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
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
    It 'rejects the retired tenant rather than preserving an old execution fallback' {
        { Resolve-RepositoryTestTenantSettings -TestTenant legacy } |
            Should -Throw '*legacy test tenant is retired*'
        { Resolve-RepositoryTestTenantSettings -TestTenant legacy -BamiValues (New-AvmTestBamiSettings) } |
            Should -Throw '*legacy test tenant is retired*'
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
}

Describe 'Candidate plan and output safety' {
    BeforeEach {
        $script:settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $script:plan = New-AvmTestBamiPlan
        $script:planArguments = @{
            Settings = $script:settings
            Repository = $script:repository.full_name
            RepositoryId = '1234'
            RepositoryOwnerId = '6844498'
            RepositorySyncRepositoryId = '1239632211'
            EntraGroupNames = @('avm-test-management-group-owners', 'avm-test-entra-readers')
        }
    }

    It 'accepts only the bounded group-based identity plan without a direct Owner assignment' {
        @($script:plan.planned_values.root_module.child_modules[0].resources |
            Where-Object { $_['mode'] -ceq 'data' }).Count | Should -Be 0
        @($script:plan.prior_state.values.root_module.child_modules[0].resources).Count | Should -Be 4
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Not -Throw
    }

    It 'requires the refreshed snapshot rather than configured values or planned data: <Case>' -ForEach @(
        @{ Case = 'missing'; Snapshot = $null }
        @{ Case = 'wrong snapshot type'; Snapshot = 'not a state document' }
        @{ Case = 'missing values'; Snapshot = @{} }
        @{ Case = 'wrong values type'; Snapshot = @{ values = @() } }
        @{ Case = 'missing root module'; Snapshot = @{ values = @{} } }
        @{ Case = 'wrong root module type'; Snapshot = @{ values = @{ root_module = @() } } }
    ) {
        $script:plan.planned_values.root_module.child_modules[0].resources +=
            $script:plan.prior_state.values.root_module.child_modules[0].resources
        $script:plan.prior_state = $Snapshot
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Throw '*requires refreshed Terraform data-source evidence*'
    }

    It 'never treats historical managed resources as planned identity scope' {
        $script:plan.prior_state.values.root_module.child_modules[0].resources += @{
            address = 'module.azure.azapi_resource.previous_identity'
            mode = 'managed'; type = 'azapi_resource'; values = @{ name = 'unrelated prior resource' }
        }
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } | Should -Not -Throw
        $script:plan.planned_values.root_module.child_modules[0].resources[0].values.name = 'wrong planned identity'
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } | Should -Throw '*expected repository*'
    }

    It 'rejects stale evidence when a required data source will be reread at apply: <Address>' -ForEach @(
        @{ Address = 'module.azure.data.azapi_client_config.current' }
        @{ Address = 'module.azure.data.azuread_client_config.current' }
        @{ Address = 'module.azure.data.azuread_group.test_permissions["avm-test-entra-readers"]' }
        @{ Address = 'module.azure.data.azuread_group.test_permissions["avm-test-management-group-owners"]' }
    ) {
        $resource = @($script:plan.prior_state.values.root_module.child_modules[0].resources |
            Where-Object { $_['address'] -ceq $Address })[0]
        $script:plan.resource_changes += @{
            address = $Address; mode = 'data'; type = $resource['type']
            change = @{ actions = @('read'); before = $resource['values']; after = @{}; after_unknown = $true }
        }
        $script:plan.planned_values.root_module.child_modules[0].resources += @{
            address = $Address; mode = 'data'; type = $resource['type']; values = @{}
        }
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } |
            Should -Throw '*requires completed plan-time data reads*'
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

    It 'rejects identity and federation deletes or replacements while allowing membership refresh' {
        foreach ($actions in @(@('delete'), @('delete', 'create'), @('create', 'delete'))) {
            $script:plan.resource_changes[0].change.actions = $actions
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

    It 'validates provider tenant and controller evidence before authorizing group membership: <Field>' -ForEach @(
        @{ Address = 'module.azure.data.azapi_client_config.current'; Field = 'tenant_id' }
        @{ Address = 'module.azure.data.azapi_client_config.current'; Field = 'subscription_id' }
        @{ Address = 'module.azure.data.azuread_client_config.current'; Field = 'tenant_id' }
        @{ Address = 'module.azure.data.azuread_client_config.current'; Field = 'client_id' }
        @{ Address = 'module.azure.data.azuread_client_config.current'; Field = 'object_id' }
    ) {
        $resource = @($script:plan.prior_state.values.root_module.child_modules[0].resources | Where-Object address -CEQ $Address)[0]
        $resource.values[$Field] = [guid]::Empty.ToString()
        { Assert-AvmBamiIdentityPlan -Plan $script:plan @script:planArguments } | Should -Throw '*Candidate membership requires*'
    }

    It 'rejects missing, duplicated, wrong-mode, wrong-type or malformed provider evidence: <Address>' -ForEach @(
        @{ Address = 'module.azure.data.azapi_client_config.current' }
        @{ Address = 'module.azure.data.azuread_client_config.current' }
    ) {
        foreach ($mutation in @('missing', 'duplicate', 'mode', 'type', 'values')) {
            $invalid = New-AvmTestBamiPlan
            $module = $invalid.prior_state.values.root_module.child_modules[0]
            $resource = @($module.resources | Where-Object { $_['address'] -ceq $Address })[0]
            switch ($mutation) {
                'missing' { $module.resources = @($module.resources | Where-Object { $_['address'] -cne $Address }) }
                'duplicate' { $module.resources += $resource.Clone() }
                'mode' { $resource.mode = 'managed' }
                'type' { $resource.type = 'terraform_remote_state' }
                'values' { $resource.values = @() }
            }
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } |
                Should -Throw '*requires verified Azure and Graph tenant/controller evidence*'
        }
    }

    It 'rejects missing, duplicated, renamed, invalid-ID or nonsecurity group evidence' {
        foreach ($address in @(
            'module.azure.data.azuread_group.test_permissions["avm-test-entra-readers"]',
            'module.azure.data.azuread_group.test_permissions["avm-test-management-group-owners"]'
        )) {
            foreach ($field in @('object_id', 'display_name', 'security_enabled')) {
                $invalid = New-AvmTestBamiPlan
                $resource = @($invalid.prior_state.values.root_module.child_modules[0].resources | Where-Object address -CEQ $address)[0]
                $resource.values[$field] = switch ($field) {
                    'object_id' { [guid]::Empty.ToString() }
                    'display_name' { 'different configured group' }
                    'security_enabled' { $false }
                }
                { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*configured security group*'
            }
            $invalid = New-AvmTestBamiPlan
            $invalid.prior_state.values.root_module.child_modules[0].resources = @(
                $invalid.prior_state.values.root_module.child_modules[0].resources | Where-Object address -CNE $address
            )
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*exactly one*'
            $invalid = New-AvmTestBamiPlan
            $invalid.prior_state.values.root_module.child_modules[0].resources += @(
                $invalid.prior_state.values.root_module.child_modules[0].resources | Where-Object address -CEQ $address
            )[0].Clone()
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*exactly one*'
        }
    }

    It 'rejects foreign or controller principals in either required membership' {
        foreach ($index in @(1, 2)) {
            foreach ($field in @('group_object_id', 'member_object_id')) {
                $invalid = New-AvmTestBamiPlan -KnownClient
                $invalid.planned_values.root_module.child_modules[0].resources[$index].values[$field] =
                    '10000000-0000-4000-8000-000000000011'
                { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*membership*'
            }
        }
        $invalid = New-AvmTestBamiPlan -KnownClient
        $invalid.planned_values.root_module.child_modules[0].resources[0].values.output.properties.principalId =
            '10000000-0000-4000-8000-000000000011'
        { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*never the controller*'
    }

    It 'requires explicit unknown masks for new identity and membership principal IDs' {
        foreach ($index in @(0, 1, 2)) {
            $invalid = New-AvmTestBamiPlan
            $invalid.resource_changes[$index].change.after_unknown = @{}
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*principal*'
        }
    }

    It 'requires every existing federation binding and never widens module execution trust' {
        foreach ($index in @(3, 4, 5)) {
            $invalid = New-AvmTestBamiPlan -KnownClient
            $invalid.planned_values.root_module.child_modules[0].resources[$index].values.body.properties.subject =
                'repository_owner_id:6844498:repository_id:1239632211:environment:avm-validation'
            { Assert-AvmBamiIdentityPlan -Plan $invalid @script:planArguments } | Should -Throw '*federation*'
        }
    }

    It 'accepts arbitrary configured group names without a fixed role/capability interface' {
        foreach ($names in @(@(), @('Data engineering testers'), @('Data engineering testers', 'quoted "group"'))) {
            $script:planArguments.EntraGroupNames = $names
            $plan = New-AvmTestBamiPlan -KnownClient -GroupNames $names
            { Assert-AvmBamiIdentityPlan -Plan $plan @script:planArguments } | Should -Not -Throw
        }
    }

    It 'adds the configured Fabric edge only when the name is in the resolved repository list' {
        $names = @('avm-test-management-group-owners', 'avm-test-entra-readers', 'avm-test-entra-fabric-admins')
        $enabled = New-AvmTestBamiPlan -KnownClient -GroupNames $names
        { Assert-AvmBamiIdentityPlan -Plan $enabled @script:planArguments } | Should -Throw '*scope*'
        $script:planArguments.EntraGroupNames = $names
        { Assert-AvmBamiIdentityPlan -Plan $enabled @script:planArguments } | Should -Not -Throw
    }

    It 'permits target-group recreation with a new resolved object ID and only the same repository principal' {
        foreach ($actions in @(@('delete', 'create'), @('create', 'delete'))) {
            $plan = New-AvmTestBamiPlan -KnownClient
            $plan.resource_changes[1].change.actions = $actions
            $plan.resource_changes[1].change.before.group_object_id = '90000000-0000-4000-8000-000000000001'
            { Assert-AvmBamiIdentityPlan -Plan $plan @script:planArguments } | Should -Not -Throw
            $plan.resource_changes[1].change.before.member_object_id = '10000000-0000-4000-8000-000000000011'
            { Assert-AvmBamiIdentityPlan -Plan $plan @script:planArguments } | Should -Throw '*individual membership edge*'
        }
    }

    It 'permits obsolete per-repository membership removal but rejects another principal or a shared-group deletion' {
        foreach ($plan in @(
            (New-AvmTestBamiPlan -KnownClient -RemovedGroup 'previous test group'),
            (New-AvmTestBamiPlan -KnownClient -LegacyMembershipMigration)
        )) {
            { Assert-AvmBamiIdentityPlan -Plan $plan @script:planArguments } | Should -Not -Throw
            $plan.resource_changes[-1].change.before.member_object_id = '10000000-0000-4000-8000-000000000011'
            { Assert-AvmBamiIdentityPlan -Plan $plan @script:planArguments } | Should -Throw '*individual membership edge*'
        }
        $plan = New-AvmTestBamiPlan -KnownClient -RemovedGroup 'previous test group'
        $plan.resource_changes[-1].type = 'azuread_group'
        { Assert-AvmBamiIdentityPlan -Plan $plan @script:planArguments } | Should -Throw '*individual membership edge*'
    }

    It 'permits only destruction of the precise obsolete direct Owner assignment, including its previous unindexed address' {
        $migration = New-AvmTestBamiPlan -KnownClient -OwnerMigration
        { Assert-AvmBamiIdentityPlan -Plan $migration @script:planArguments } | Should -Not -Throw
        $migration.resource_changes[-1].address = 'module.azure.azapi_resource.identity_role_assignment'
        $migration.resource_changes[-1].Remove('previous_address')
        { Assert-AvmBamiIdentityPlan -Plan $migration @script:planArguments } | Should -Not -Throw
        { Assert-AvmBamiIdentityPlan -Plan (New-AvmTestBamiPlan -OwnerMigration) @script:planArguments } |
            Should -Throw '*verified permission migration*'
    }

    It 'rejects wrong-target Owner deletion evidence: <Field>' -ForEach @(
        @{ Field = 'type'; Value = 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' }
        @{ Field = 'parent_id'; Value = '/providers/Microsoft.Management/managementGroups/administration' }
        @{ Field = 'name'; Value = '10000000-0000-4000-8000-000000000099' }
        @{ Field = 'id'; Value = '/providers/Microsoft.Management/managementGroups/other/providers/Microsoft.Authorization/roleAssignments/10000000-0000-4000-8000-000000000099' }
        @{ Field = 'roleDefinitionId'; Value = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c' }
        @{ Field = 'principalId'; Value = '10000000-0000-4000-8000-000000000011' }
        @{ Field = 'principalType'; Value = 'Group' }
        @{ Field = 'previous_address'; Value = 'module.azure.azapi_resource.controller_role' }
    ) {
        $migration = New-AvmTestBamiPlan -KnownClient -OwnerMigration
        $change = $migration.resource_changes[-1]
        if ($Field -ceq 'previous_address') { $change[$Field] = $Value }
        elseif ($Field -in @('roleDefinitionId', 'principalId', 'principalType')) { $change.change.before.body.properties[$Field] = $Value }
        else { $change.change.before[$Field] = $Value }
        { Assert-AvmBamiIdentityPlan -Plan $migration @script:planArguments } | Should -Throw '*exact obsolete*'
    }

    It 'never accepts replacements, forget actions, duplicate Owner deletions, or a new direct Owner grant' {
        foreach ($actions in @(@('create', 'delete'), @('delete', 'create'), @('forget'), @('create'), @('update'))) {
            $migration = New-AvmTestBamiPlan -KnownClient -OwnerMigration
            $migration.resource_changes[-1].change.actions = $actions
            { Assert-AvmBamiIdentityPlan -Plan $migration @script:planArguments } | Should -Throw
        }
        $migration = New-AvmTestBamiPlan -KnownClient -OwnerMigration
        $duplicate = $migration.resource_changes[-1].Clone()
        $duplicate.address = 'module.azure.azapi_resource.identity_role_assignment'
        $migration.resource_changes += $duplicate
        { Assert-AvmBamiIdentityPlan -Plan $migration @script:planArguments } | Should -Throw '*exact obsolete*'
        $migration = New-AvmTestBamiPlan -KnownClient -OwnerMigration
        $migration.planned_values.root_module.child_modules[0].resources += @{
            address = 'module.azure.azapi_resource.identity_role_assignment[0]'; mode = 'managed'; type = 'azapi_resource'
            values = $migration.resource_changes[-1].change.before
        }
        { Assert-AvmBamiIdentityPlan -Plan $migration @script:planArguments } | Should -Throw '*scope*'
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
    It 'resolves configured display names and creates only dynamic individual edges without a fixed group-ID interface' {
        $azure = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure' 'main.tf')
        $variables = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure' 'variables.tf')
        $bami = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'main.tf')
        $workflow = Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'repository-management-sync-repository.yml')
        $azure | Should -Match 'resource "azuread_group_member" "test_permissions"'
        $azure | Should -Match 'for_each\s*=\s*var.entra_group_names'
        $azure | Should -Match 'display_name\s*=\s*each.value'
        $azure | Should -Not -Match 'removed\s*\{|destroy\s*=\s*false|resource "azuread_group"'
        $variables | Should -Match '(?s)variable "expected_identity_context".*?nullable\s*=\s*false'
        $bami | Should -Match 'entra_group_names\s*=\s*var.entra_group_names'
        $workflow | Should -Not -Match 'TEST_BAMI_(ENTRA_READERS|TEST_IDENTITY_OWNERS|FABRIC_ADMINS)_GROUP_ID'
        $azure | Should -Not -Match 'avm-test-|grp-sec-avm|fabric_admin|bami_group_settings'
        $azure | Should -Match 'condition\s*=\s*local.member_is_repository_identity'
    }

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

    It 'removes retired Azure execution from the ordinary root while keeping BAMI providers and backend independent' {
        $main = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'main.tf')
        $legacy = [regex]::Match($main, '(?s)^module "azure" \{.*?\n\}').Value
        $legacy | Should -BeNullOrEmpty
        $main | Should -Match 'arm_client_id\s*=\s*local.test_settings.client_id'
        $main | Should -Match 'arm_tenant_id\s*=\s*local.test_settings.tenant_id'
        $main | Should -Match 'test_subscription_ids\s*=\s*local.test_settings.test_subscription_ids'
        $main | Should -Match 'module "bami"'
        $main | Should -Match 'github_repository_id\s*=\s*module.github.repository_id'
        $main | Should -Match 'github_organization_id\s*=\s*module.github.organization_id'
        $main | Should -Not -Match 'depends_on'
        Test-Path -LiteralPath (Join-Path $script:root 'repository-management' 'repository-sync' 'bami-identity' 'terraform.tf') | Should -BeFalse
        $retirement = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'retired-identity.tf')
        $retirement | Should -Match '(?s)removed \{\s*from = module.azure\s+lifecycle \{\s*destroy = false'
        $retirement | Should -Not -Match 'module.github|bami-identities|state (rm|mv)|refresh\s*='
        $providers = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'terraform.tf')
        $providers | Should -Match 'backend "azurerm" \{\}'
        $providers | Should -Match 'provider "github"'
        ([regex]::Matches($providers, 'use_cli\s*=\s*false')).Count | Should -Be 2
        $providers | Should -Match 'tenant_id\s*=\s*var.bami_test_settings == null \? null : var.bami_test_settings.tenant_id'
        $providers | Should -Match 'client_id\s*=\s*var.bami_test_settings == null \? null : var.bami_test_settings.controller_client_id'
        $workflow = Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'repository-management-sync-repository.yml')
        $workflow | Should -Not -Match 'vars\.ARM_(TENANT_ID|CLIENT_ID|SUBSCRIPTION_ID)|vars\.TEST_SUBSCRIPTION_IDS'
    }

    It 'uses mock providers only for the explicitly permitted retirement-state seed test' {
        $test = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'tests' 'retired_identity.tftest.hcl')
        foreach ($provider in @('azapi', 'azuread', 'github')) {
            $test | Should -Match ('mock_provider "' + $provider + '"')
        }
        $test | Should -Match '(?s)run "seed_only_disposable_mock_retired_state" \{\s*command\s*=\s*apply\s*state_key\s*=\s*"retired-fixture"'
        $test | Should -Match '(?s)run "forget_only_retired_state_without_refresh" \{\s*command\s*=\s*plan\s*state_key\s*=\s*"retired-fixture"'
        $test | Should -Not -Match '(?m)^provider\s+"|backend|token|client_secret'
    }

    It 'uses the existing per-module identity for both validation subjects without changing the original trust' {
        $azure = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure' 'main.tf')
        $original = [regex]::Match($azure, '(?sm)^resource "azapi_resource" "identity_federated_credentials" \{.*?^\}').Value
        $original | Should -Match 'for_each\s*=\s*var.github_repository_environment_names'
        $baseSubject = 'repository_owner_id:${var.github_organization_id}:repository_id:${var.github_repository_id}:environment:${each.value}:job_workflow_ref:${var.github_job_workflow_ref}'
        $callerBinding = 'var.github_workflow_ref == null ? "" : ":workflow_ref:${var.github_workflow_ref}"'
        $original | Should -Match ('(?s)subject\s*=\s*join\("",\s*\[\s*"' +
            [regex]::Escape($baseSubject) + '",\s*' + [regex]::Escape($callerBinding) + '\s*\]\)')
        $variables = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'modules' 'azure' 'variables.tf')
        foreach ($name in @('identity_name', 'github_workflow_ref')) {
            $variable = [regex]::Match($variables, '(?sm)^variable "' + $name + '" \{.*?^\}').Value
            $variable | Should -Match '\bdefault\s*=\s*null\b'
        }
        $validation = [regex]::Match($azure, '(?sm)^resource "azapi_resource" "validation_federated_credential" \{.*?^\}').Value
        $validation | Should -Not -BeNullOrEmpty
        $validation | Should -Match 'parent_id\s*=\s*azapi_resource.identity.id'
        $validation | Should -Match 'locks\s*=\s*\[azapi_resource.identity.id\]'
        $validation | Should -Match 'name\s*=\s*"\$\{local.owner_repo_name\}-avm-validation"'
        $validation | Should -Match 'subject\s*=\s*"repository_owner_id:\$\{var.github_organization_id\}:repository_id:\$\{var.repository_sync_repository_id\}:environment:avm-validation"'
        $validation | Should -Not -Match 'repository_owner_id:[0-9]|repository_id:[0-9]'
        $validation | Should -Not -Match 'job_workflow_ref:|ref:refs/heads/'
        $ordinary = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'main.tf')
        $ordinary | Should -Match 'source\s*=\s*"\./modules/azure"'
        $ordinary | Should -Match 'repository_sync_repository_id\s*=\s*var.repository_sync_repository_id'
        $ordinary | Should -Not -Match 'resource\s+"azapi_resource"\s+"identity"'
        $ordinary | Should -Not -Match '(?m)^\s*(identity_name|github_workflow_ref)\s*='
    }

    It 'exposes only the verified BAMI test settings to plan-only consumers' {
        $output = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'outputs.tf')
        $output | Should -Match '(?s)output "test_settings" \{\s*description\s*=\s*"[^"]+"\s*value\s*=\s*local.test_settings\s*\}'
        $locals = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'locals.tf')
        $locals | Should -Not -Match 'module.azure|var.test_subscription_ids'
        foreach ($field in @('tenant_id', 'test_subscription_ids')) {
            $locals | Should -Match ('\b' + $field + '\s*=\s*var.bami_test_settings\.' + $field + '\b')
        }
        $locals | Should -Match 'client_id\s*=\s*module.bami\[0\].client_id'
        $settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $subscriptions = ConvertFrom-AvmTestTenantJson -Json $settings.TEST_BAMI_SUBSCRIPTION_IDS
        $subscriptions.Count | Should -Be 28
        $subscriptions.id | Should -Not -Contain $settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID
        $subscriptions.id | Should -Not -Contain $settings.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
    }

    It 'validates selected settings and the trusted BAMI run context before mutations without an activation switch' {
        $source = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1')
        $source | Should -Not -Match 'bamiTestTenantSyncEnabled|PendingTestTenantActivation|stateLayout|state_layout|unified-v1'
        $source | Should -Match 'Assert-AvmBamiRepositorySyncRunContext -PlanOnly \$planOnly'
        $source.IndexOf('Assert-AvmBamiRepositorySyncRunContext') | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeGreaterThan 0
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $source.IndexOf('Resolve-AvmRepositorySyncContext') | Should -BeGreaterThan $source.IndexOf('Resolve-RepositoryTestTenantSettings')
        $source.IndexOf('Resolve-AvmRepositorySyncContext') | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $source.IndexOf('Resolve-RepositoryTestTenantSettings') | Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source | Should -Not -Match 'Invoke-AvmBamiRepositoryIdentity|candidateSettings'
        $source | Should -Match 'ConvertTo-AvmRepositoryTerraformSettings'
        $workflow = Get-Content -Raw (Join-Path $script:root '.github' 'workflows' 'repository-management-sync-repository.yml')
        $workflow | Should -Match '-bamiSettings \$bamiSettings'
        $source | Should -Match '\[string\]\$repositorySyncRepositoryId = \$env:GITHUB_REPOSITORY_ID'
        $workflow | Should -Not -Match '-repositorySyncRepositoryId'
        $workflow | Should -Not -Match 'AVM_BAMI_TEST_TENANT_SYNC_ENABLED|bamiTestTenantSyncEnabled|AVM_REPOSITORY_SYNC_STATE_LAYOUT|StateLayout'
        $workflow | Should -Not -Match 'Write-Output "Token:'
        $helper = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
        $helper | Should -Match 'Assert-AvmBamiRepositorySyncRunContext -PlanOnly \$PlanOnly'
        $helper | Should -Match '\$env:GITHUB_ACTIONS -cne ''true'''
        $helper | Should -Match '\$env:GITHUB_REPOSITORY -cne ''Azure/azure-verified-modules-tools'''
        $helper | Should -Match '\$env:GITHUB_EVENT_NAME -ceq ''workflow_dispatch'''
        $helper | Should -Match '\$env:GITHUB_REF -cne ''refs/heads/main'''
        $helper | Should -Not -Match 'state (mv|rm|push|pull)|force-unlock|Import-Az|az login|Set-Az|StateLayout|unified-v1'
        $variables = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-sync' 'terraform' 'variables.tf')
        $variables | Should -Not -Match 'state_layout|unified-v1'
    }
}
