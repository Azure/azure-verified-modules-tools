BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleConfig.ps1')
    . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleIdentitySync.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'BicepIdentities.ps1')
    $script:configuration = ConvertFrom-AvmTestTenantJson -Json (
        Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'bicep-config' 'config.json') -Raw
    )
}

Describe 'Bicep module identity configuration' {
    It 'uses exactly the Terraform defaults for every unlisted root, including Fabric and management-group modules' {
        $terraform = Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'repository-config' 'config.json') -Raw | ConvertFrom-Json
        $defaults = @($terraform.repositoryGroups | Where-Object name -CEQ 'default')[0].entraGroups
        $paths = @(
            'avm/res/new/service', 'avm/res/fabric/capacity', 'avm/res/management/management-group',
            'avm/ptn/authorization/role-assignment', 'avm/res/managed-services/registration-definition',
            'avm/ptn/subscription/service-health-alerts'
        )
        $selected = Resolve-AvmBicepModuleSettings -ModulePaths $paths -Configuration $script:configuration
        foreach ($path in $paths) { $selected[$path] | Should -Be $defaults }
    }

    It 'selects explicit privileged-role and persistent-image permissions, including shared HCI dependencies' {
        $paths = @(
            'avm/res/storage/storage-account', 'avm/ptn/authorization/pim-role-assignment',
            'avm/ptn/lz/sub-vending', 'avm/res/azure-stack-hci/marketplace-gallery-image',
            'avm/res/hybrid-container-service/provisioned-cluster-instance', 'avm/res/azure-stack-hci/cluster'
        )
        $selected = Resolve-AvmBicepModuleSettings -ModulePaths $paths -Configuration $script:configuration
        foreach ($path in $paths) {
            $selected[$path] | Should -Contain 'avm-test-management-group-iam-admins'
            $selected[$path] | Should -Contain 'avm-test-entra-readers'
            $selected[$path] | Should -Contain 'avm-test-management-group-owners'
        }
        $selected[$paths[4]] | Should -Contain 'avm-test-subscription-persistent-readers'
        $selected[$paths[5]] | Should -Contain 'avm-test-subscription-persistent-readers'
        $selected[$paths[3]] | Should -Not -Contain 'avm-test-subscription-persistent-readers'
    }

    It 'accumulates ordered names without replacing defaults and validates unmatched declarations' {
        $path = 'avm/res/fabric/capacity'
        $config = @{ moduleGroups = @(
            @{ name = 'last'; order = 10; modules = @($path); entraGroups = @('Extra', 'Readers') }
            @{ name = 'default'; order = -1; modules = @('*'); entraGroups = @('Readers', 'Owners'); testTenant = 'bami' }
            @{ name = 'first'; order = 5; modules = @($path); entraGroups = @('Early') }
        ) }
        (Resolve-AvmBicepModuleSettings -ModulePaths @($path) -Configuration $config)[$path] |
            Should -Be @('Readers', 'Owners', 'Early', 'Extra')
        $config.moduleGroups += @{ name = 'invalid'; modules = @('avm/res/new/service'); entraGroups = 'not-an-array' }
        { Resolve-AvmBicepModuleSettings -ModulePaths @($path) -Configuration $config } | Should -Throw
    }

    It 'rejects incomplete or ambiguous module configuration: <Case>' -ForEach @(
        @{ Case = 'missing tenant'; Config = @{ moduleGroups = @(@{ name = 'default'; modules = @('*') }) }; Paths = @('avm/res/new/service') }
        @{ Case = 'legacy tenant'; Config = @{ moduleGroups = @(@{ name = 'default'; modules = @('*'); testTenant = 'legacy' }) }; Paths = @('avm/res/new/service') }
        @{ Case = 'selector glob'; Config = @{ moduleGroups = @(@{ name = 'default'; modules = @('avm/res/*'); testTenant = 'bami' }) }; Paths = @('avm/res/new/service') }
        @{ Case = 'unknown setting'; Config = @{ moduleGroups = @(@{ name = 'default'; modules = @('*'); testTenant = 'bami'; entraGroup = @() }) }; Paths = @('avm/res/new/service') }
        @{ Case = 'empty inventory'; Config = @{ moduleGroups = @(@{ name = 'default'; modules = @('*'); testTenant = 'bami' }) }; Paths = @() }
        @{ Case = 'duplicate inventory'; Config = @{ moduleGroups = @(@{ name = 'default'; modules = @('*'); testTenant = 'bami' }) }; Paths = @('avm/res/new/service', 'avm/res/new/service') }
    ) {
        { Resolve-AvmBicepModuleSettings -ModulePaths $Paths -Configuration $Config } | Should -Throw
    }

    It 'keeps identity names stable and distinguishes paths that flatten to the same text' {
        Get-AvmBicepModuleIdentityName -ModulePath 'avm/res/storage/storage-account' |
            Should -BeExactly 'id-avm-bicep-avm-res-storage-storage-account-3ecbb5ba'
        (Get-AvmBicepModuleIdentityName -ModulePath 'avm/res/a-b/c') |
            Should -Not -Be (Get-AvmBicepModuleIdentityName -ModulePath 'avm/res/a/b-c')
    }

    It 'rejects noncanonical roots' -ForEach @(
        'avm/res/storage/storage-account/blob-service', 'avm/res/storage', 'AVM/res/storage/storage-account',
        'avm/res/storage/../main', 'avm\res\storage\storage-account', 'avm/res/storage/*', 'avm/res/storage/a--b'
    ) {
        { Get-AvmBicepModuleIdentityName -ModulePath $_ } | Should -Throw
    }
}

Describe 'Bicep module client-ID mapping' {
    BeforeEach {
        $script:settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $script:modules = New-AvmTestBicepIdentityModules
        $script:identities = New-AvmTestBicepIdentityOutputs
    }

    It 'returns only a compact, sorted root-path-to-client-ID object from complete applied output' {
        $mapping = ConvertTo-AvmBicepIdentityMapping -Identities $script:identities -ModulePaths @($script:modules.Keys) -Settings $script:settings
        $json = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping
        $json | Should -Not -Match '\r|\n|tenant_id|identity_resource_id'
        $parsed = ConvertFrom-AvmTestTenantJson -Json $json
        @($parsed.Keys) | Should -Be @('avm/res/fabric/capacity', 'avm/res/storage/storage-account')
        $parsed['avm/res/fabric/capacity'] | Should -BeExactly '10000000-0000-4000-8000-000000000006'
    }

    It 'accepts exactly 48 KiB and rejects one additional UTF-8 byte' {
        $exact = New-AvmTestSizedBicepClientIds -ByteCount 49152
        $json = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $exact
        [Text.Encoding]::UTF8.GetByteCount($json) | Should -Be 49152
        $oversized = New-AvmTestSizedBicepClientIds -ByteCount 49153
        [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $oversized -Compress)) | Should -Be 49153
        { ConvertTo-AvmBicepModuleClientIdJson -ClientIds $oversized } | Should -Throw '*48 KB*'
    }

    It 'rejects incomplete, misbound, shared, or aliased identity outputs: <Case>' -ForEach @(
        @{ Case = 'missing module'; Edit = { param($v) $v.Remove('avm/res/fabric/capacity') } }
        @{ Case = 'extra module'; Edit = { param($v) $v['avm/res/new/service'] = $v['avm/res/fabric/capacity'] } }
        @{ Case = 'wrong tenant'; Edit = { param($v) $v['avm/res/fabric/capacity'].tenant_id = '90000000-0000-4000-8000-000000000001' } }
        @{ Case = 'wrong resource'; Edit = { param($v) $v['avm/res/fabric/capacity'].identity_resource_id = '/subscriptions/foreign/identity' } }
        @{ Case = 'malformed client'; Edit = { param($v) $v['avm/res/fabric/capacity'].client_id = 'invalid' } }
        @{ Case = 'controller'; Edit = { param($v) $v['avm/res/fabric/capacity'].client_id = '10000000-0000-4000-8000-000000000002' } }
        @{ Case = 'shared Bicep identity'; Edit = { param($v) $v['avm/res/fabric/capacity'].client_id = '10000000-0000-4000-8000-000000000004' } }
        @{ Case = 'duplicate client'; Edit = { param($v) $v['avm/res/fabric/capacity'].client_id = $v['avm/res/storage/storage-account'].client_id } }
        @{ Case = 'extra fields'; Edit = { param($v) $v['avm/res/fabric/capacity'].unexpected = 'value' } }
    ) {
        & $Edit $script:identities
        { ConvertTo-AvmBicepIdentityMapping -Identities $script:identities -ModulePaths @($script:modules.Keys) -Settings $script:settings } |
            Should -Throw
    }

    It 'permits only additive publication and normalizes GUID casing without rebinding' {
        $mapping = ConvertTo-AvmBicepIdentityMapping -Identities $script:identities -ModulePaths @($script:modules.Keys) -Settings $script:settings
        $existing = '{"avm/res/fabric/capacity":"10000000-0000-4000-8000-000000000006"}'
        { Assert-AvmBicepModuleMappingExtension -ExistingJson $existing -ClientIds $mapping } | Should -Not -Throw
        $mapping.Remove('avm/res/fabric/capacity')
        { Assert-AvmBicepModuleMappingExtension -ExistingJson $existing -ClientIds $mapping } | Should -Throw '*removed or retargeted*'
        $mapping['avm/res/fabric/capacity'] = '90000000-0000-4000-8000-000000000006'
        { Assert-AvmBicepModuleMappingExtension -ExistingJson $existing -ClientIds $mapping } | Should -Throw '*removed or retargeted*'
    }

    It 'does not overwrite malformed or duplicate existing JSON: <Existing>' -ForEach @(
        @{ Existing = '{}' }
        @{ Existing = '[]' }
        @{ Existing = '{"avm/res/fabric/capacity":"invalid"}' }
        @{ Existing = '{"avm/res/fabric/capacity":"10000000-0000-4000-8000-000000000006","avm/res/fabric/capacity":"10000000-0000-4000-8000-000000000016"}' }
    ) {
        { Assert-AvmBicepModuleMappingExtension -ExistingJson $Existing -ClientIds @{ 'avm/res/fabric/capacity' = '10000000-0000-4000-8000-000000000006' } } |
            Should -Throw
    }
}

Describe 'Bicep identity saved-plan ownership guard' {
    BeforeEach {
        $script:settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $script:modules = New-AvmTestBicepIdentityModules
        $script:context = New-AvmTestBicepIdentityContext
        $script:plan = New-AvmTestBicepIdentityPlan -KnownClient
        $script:guard = @{ Plan = $script:plan; Settings = $script:settings; Modules = $script:modules; Context = $script:context }
    }

    It 'accepts both existing identities and new identities with explicitly unknown outputs' -ForEach @($true, $false) {
        $script:guard.Plan = New-AvmTestBicepIdentityPlan -KnownClient:$_
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Not -Throw
    }

    It 'keeps module and Tools federation names distinct and binds caller and reusable workflows' {
        $resources = $script:plan.planned_values.root_module.child_modules[0].resources
        $credentials = @($resources | Where-Object { $_.values['type'] -like '*/federatedIdentityCredentials@*' })
        @($credentials.values.name | Select-Object -Unique) | Should -HaveCount 2
        $moduleCredential = @($credentials | Where-Object { $_.address -like '*identity_federated_credentials*' })[0]
        $moduleCredential.values.body.properties.subject |
            Should -BeExactly 'repository_owner_id:6844498:repository_id:447791597:environment:avm-validation:job_workflow_ref:Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main:workflow_ref:Azure/bicep-registry-modules/.github/workflows/avm.res.fabric.capacity.yml@refs/heads/main'
    }

    It 'rejects incomplete, destructive, foreign, or widened plans: <Case>' -ForEach @(
        @{ Case = 'incomplete'; Edit = { param($p) $p.complete = $false } }
        @{ Case = 'errored'; Edit = { param($p) $p.errored = $true } }
        @{ Case = 'replacement'; Edit = { param($p) $p.resource_changes[0].change.actions = @('delete', 'create') } }
        @{ Case = 'missing module'; Edit = { param($p) $p.planned_values.root_module.child_modules = @($p.planned_values.root_module.child_modules[0]) } }
        @{ Case = 'removed module'; Edit = { param($p) $p.resource_changes += @{ address = 'module.bicep["avm/res/removed/module"].azapi_resource.identity'; mode = 'managed'; type = 'azapi_resource'; provider_name = 'registry.terraform.io/azure/azapi'; change = @{ actions = @('delete') } } } }
        @{ Case = 'shared identity'; Edit = { param($p) $p.planned_values.root_module.child_modules[0].resources[0].values.name = 'id-avm-bicep' } }
        @{ Case = 'foreign existing state'; Edit = { param($p) $p.resource_changes[0].change.before.id = '/shared/identity' } }
        @{ Case = 'foreign provider'; Edit = { param($p) $p.resource_changes[0].provider_name = 'registry.terraform.io/example/azapi' } }
        @{ Case = 'import'; Edit = { param($p) $p.resource_changes[0].change.importing = @{ id = '/foreign/identity' } } }
        @{ Case = 'state move'; Edit = { param($p) $p.resource_changes[0].previous_address = 'module.shared.azapi_resource.identity' } }
        @{ Case = 'unrestricted federation'; Edit = { param($p) $p.planned_values.root_module.child_modules[0].resources[-2].values.body.properties.subject = 'repo:Azure/bicep-registry-modules:environment:avm-validation' } }
        @{ Case = 'another caller'; Edit = { param($p) $p.planned_values.root_module.child_modules[0].resources[-2].values.body.properties.subject = $p.planned_values.root_module.child_modules[1].resources[-2].values.body.properties.subject } }
        @{ Case = 'wrong Graph tenant'; Edit = { param($p) $p.prior_state.values.root_module.child_modules[0].resources[1].values.tenant_id = '90000000-0000-4000-8000-000000000001' } }
        @{ Case = 'wrong group'; Edit = { param($p) $p.prior_state.values.root_module.child_modules[0].resources[2].values.display_name = 'foreign group' } }
        @{ Case = 'duplicate client'; Edit = { param($p) $p.planned_values.root_module.child_modules[1].resources[0].values.output.properties.clientId = '10000000-0000-4000-8000-000000000006' } }
        @{ Case = 'no data evidence'; Edit = { param($p) $p.Remove('prior_state') } }
        @{ Case = 'direct role assignment'; Edit = { param($p) $p.resource_changes += @{ address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.identity_role_assignment'; type = 'azapi_resource'; mode = 'managed'; provider_name = 'registry.terraform.io/azure/azapi'; change = @{ actions = @('delete') } } } }
    ) {
        & $Edit $script:plan
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw
    }

    It 'allows revoking only a membership belonging to the same dedicated principal' {
        $removed = @{
            address = 'module.bicep["avm/res/fabric/capacity"].azuread_group_member.test_permissions["retired group"]'
            mode = 'managed'; type = 'azuread_group_member'; provider_name = 'registry.terraform.io/hashicorp/azuread'
            change = @{
                actions = @('delete'); after = $null
                before = @{ group_object_id = '10000000-0000-4000-8000-000000000099'; member_object_id = '10000000-0000-4000-8000-000000000007' }
            }
        }
        $script:plan.resource_changes += $removed
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Not -Throw
        $removed.change.before.member_object_id = '10000000-0000-4000-8000-000000000011'
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw
    }
}
