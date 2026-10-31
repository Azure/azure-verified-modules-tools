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

Describe 'Bicep sync trusted run context' {
    BeforeEach {
        $script:originalBicepSyncEnvironment = @{}
        foreach ($name in @(
                'GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_WORKFLOW_REF',
                'GITHUB_REPOSITORY_ID', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA'
            )) {
            $script:originalBicepSyncEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_EVENT_NAME = 'schedule'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_WORKFLOW_REF =
            'Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@refs/heads/main'
        $env:GITHUB_REPOSITORY_ID = '1239632211'
        $env:GITHUB_RUN_ID = '123456789'
        $env:GITHUB_RUN_ATTEMPT = '1'
        $env:GITHUB_SHA = '0123456789012345678901234567890123456789'
    }

    AfterEach {
        foreach ($name in $script:originalBicepSyncEnvironment.Keys) {
            $value = if ($null -eq $script:originalBicepSyncEnvironment[$name]) {
                [NullString]::Value
            }
            else {
                $script:originalBicepSyncEnvironment[$name]
            }
            [Environment]::SetEnvironmentVariable($name, $value)
        }
    }

    It 'accepts scheduled main with exact workflow evidence' {
        $context = Resolve-AvmBicepSyncRunContext
        $context.WorkflowRef |
            Should -BeExactly 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@refs/heads/main'
        $context.IsManualBranch | Should -BeFalse
    }

    It 'accepts a manually dispatched branch only when its workflow evidence matches' {
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $env:GITHUB_REF = 'refs/heads/jaredholgate-microsoft-subscription-vending-identity-sync'
        $env:GITHUB_WORKFLOW_REF =
            'Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@refs/heads/jaredholgate-microsoft-subscription-vending-identity-sync'

        $context = Resolve-AvmBicepSyncRunContext
        $context.IsManualBranch | Should -BeTrue
        (Get-AvmBicepIdentityPublicationContext).workflowRef | Should -BeExactly $env:GITHUB_WORKFLOW_REF
    }

    It 'rejects scheduled branch runs, tags, and mismatched workflow evidence: <Case>' -ForEach @(
        @{ Case = 'scheduled branch'; Event = 'schedule'; Ref = 'refs/heads/feature'; WorkflowRef = 'refs/heads/feature' }
        @{ Case = 'tag'; Event = 'workflow_dispatch'; Ref = 'refs/tags/v1'; WorkflowRef = 'refs/tags/v1' }
        @{ Case = 'mismatched workflow'; Event = 'workflow_dispatch'; Ref = 'refs/heads/feature'; WorkflowRef = 'refs/heads/main' }
    ) {
        $env:GITHUB_EVENT_NAME = $Event
        $env:GITHUB_REF = $Ref
        $env:GITHUB_WORKFLOW_REF =
            "Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@$WorkflowRef"

        { Resolve-AvmBicepSyncRunContext } | Should -Throw '*trusted Tools main or a manual trusted-repository branch*'
    }
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

    It 'selects the bootstrap subscription-vending identity only for its exact root' {
        $identities = Resolve-AvmBicepModuleExistingIdentities -ModulePaths @(
            'avm/ptn/lz/sub-vending', 'avm/res/storage/storage-account'
        ) -Configuration $script:configuration
        @($identities.Keys) | Should -Be @('avm/ptn/lz/sub-vending')
        $identities['avm/ptn/lz/sub-vending'].name | Should -BeExactly 'id-avm-subscription-vending'
        $identities['avm/ptn/lz/sub-vending'].resourceGroupName | Should -BeExactly 'rg-avm-managed-identities'
        $identities['avm/ptn/lz/sub-vending'].manageEntraGroups | Should -BeTrue
    }

    It 'binds the billing scope only to the configured vending root with complete bootstrap evidence' {
        $settings = New-AvmTestBamiSettings
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID =
            '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-avm-managed-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-avm-subscription-vending'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID = '10000000-0000-4000-8000-000000000006'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID = '10000000-0000-4000-8000-000000000007'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID = 'avm-subscription-vending'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE =
            '/providers/Microsoft.Billing/billingAccounts/account:segment/billingProfiles/profile/invoiceSections/section'

        $scopes = Resolve-AvmBicepSubscriptionVendingBillingScopes -Configuration $script:configuration -Values $settings
        $scopes.Keys | Should -Be @('avm/ptn/lz/sub-vending')
        $scopes['avm/ptn/lz/sub-vending'] | Should -BeExactly $settings.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE
        ConvertTo-AvmBicepModuleBillingScopeJson -BillingScopes $scopes |
            Should -BeExactly ('{"avm/ptn/lz/sub-vending":"' + $settings.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE + '"}')

        $settings.Remove('TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE')
        { Resolve-AvmBicepSubscriptionVendingBillingScopes -Configuration $script:configuration -Values $settings } |
            Should -Throw '*invoice-section*'
    }

    It 'publishes an empty billing scope map only when the vending selector is absent' {
        $configuration = ConvertFrom-AvmTestTenantJson -Json (
            Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'bicep-config' 'config.json') -Raw
        )
        $configuration['moduleGroups'] = @($configuration['moduleGroups'] | Where-Object { $_['name'] -cne 'subscription-vending-identity' })
        $scopes = Resolve-AvmBicepSubscriptionVendingBillingScopes -Configuration $configuration -Values (New-AvmTestBamiSettings)
        $scopes.Count | Should -Be 0
        ConvertTo-AvmBicepModuleBillingScopeJson -BillingScopes $scopes | Should -BeExactly '{}'
        { ConvertTo-AvmBicepModuleBillingScopeJson -BillingScopes @{ 'avm/res/storage/storage-account' = 'scope' } } |
            Should -Throw '*canonical subscription-vending root*'
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

    It 'keeps the complete readable path without a hash or duplicated avm prefix' {
        Get-AvmBicepModuleIdentityName -ModulePath 'avm/res/storage/storage-account' |
            Should -BeExactly 'id-test-bicep-avm-res-storage-storage-account'
        Get-AvmTestIdentityName -ModulePath 'avm/res/storage/storage-account' -Legacy |
            Should -BeExactly 'id-avm-bicep-avm-res-storage-storage-account-3ecbb5ba'
        $longest = 'avm/res/a/' + ('b' * 58)
        (Get-AvmBicepModuleIdentityName -ModulePath $longest) | Should -BeExactly ('id-test-bicep-' + $longest.Replace('/', '-'))
        (Get-AvmTestIdentityName -ModulePath $longest -Legacy).Length | Should -Be 90
        { Get-AvmBicepModuleIdentityName -ModulePath ($longest + 'b') } | Should -Throw '*68 characters*'
    }

    It 'rejects future flattened-path collisions instead of hashing or truncating them' {
        $paths = @('avm/res/a-b/c', 'avm/res/a/b-c')
        (Get-AvmBicepModuleIdentityName -ModulePath $paths[0]) |
            Should -BeExactly (Get-AvmBicepModuleIdentityName -ModulePath $paths[1])
        { Resolve-AvmBicepModuleSettings -ModulePaths $paths -Configuration $script:configuration } |
            Should -Throw '*unique*'
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

Describe 'Bicep module identity rename evidence' {
    BeforeEach {
        Mock Get-AvmBicepIdentityPublicationContext {
            [ordered]@{
                repositoryId = '1239632211'
                workflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@refs/heads/main'
                commit = '0123456789012345678901234567890123456789'
                runId = '123456789'
                runAttempt = '1'
            }
        }
        $script:settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $script:migration = New-AvmTestBicepIdentityMigration
        $script:mapping = ConvertTo-AvmBicepIdentityMapping -Identities $script:migration.after `
            -ModulePaths @($script:migration.after.Keys) -Settings $script:settings
    }

    It 'accepts a partial rename without requiring unchanged modules in its before and after evidence' {
        $script:migration.before.Remove('avm/res/storage/storage-account')
        $script:migration.after.Remove('avm/res/storage/storage-account')
        $previous = ConvertFrom-AvmBicepIdentityMigration -Migration $script:migration -ClientIds $script:mapping -Settings $script:settings
        $previous.Count | Should -Be 1
        $previous['avm/res/fabric/capacity'] | Should -BeExactly '10000000-0000-4000-8000-000000000106'
    }

    It 'rejects untyped, additional or misbound migration evidence: <Case>' -ForEach @(
        @{ Case = 'string version'; Edit = { param($m) $m.schemaVersion = '1' } }
        @{ Case = 'floating version'; Edit = { param($m) $m.schemaVersion = [double]1 } }
        @{ Case = 'additional field'; Edit = { param($m) $m.approved = $true } }
        @{ Case = 'additional context'; Edit = { param($m) $m.context.approved = $true } }
        @{ Case = 'current rather than legacy before resource'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].identity_resource_id = $m.after['avm/res/fabric/capacity'].identity_resource_id } }
        @{ Case = 'duplicate previous client'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].client_id = $m.before['avm/res/storage/storage-account'].client_id } }
        @{ Case = 'different after module'; Edit = { param($m)
            $m.after['avm/res/new/module'] = $m.after['avm/res/fabric/capacity']
            $m.after.Remove('avm/res/fabric/capacity')
        } }
    ) {
        & $Edit $script:migration
        { ConvertFrom-AvmBicepIdentityMigration -Migration $script:migration -ClientIds $script:mapping -Settings $script:settings } |
            Should -Throw
    }

    It 'rejects reuse of an old client anywhere in a matching proposed mapping' {
        $oldClient = $script:migration.before['avm/res/fabric/capacity'].client_id
        $script:migration.after['avm/res/storage/storage-account'].client_id = $oldClient
        $script:mapping['avm/res/storage/storage-account'] = $oldClient
        { ConvertFrom-AvmBicepIdentityMigration -Migration $script:migration -ClientIds $script:mapping -Settings $script:settings } |
            Should -Throw '*stale or reused IDs*'
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

    Describe 'Bicep subscription-vending state retirement preparation' {
        BeforeEach {
            $script:stateSecret = 'synthetic-historical-identity-must-not-be-disclosed'
            $script:recoveryBackend = @{
                TenantId = '20000000-0000-4000-8000-000000000001'
                SubscriptionId = '20000000-0000-4000-8000-000000000002'
                ClientId = '20000000-0000-4000-8000-000000000003'
                StorageAccountName = 'fixturestatestore'
                ContainerName = 'tfstate'
            }
            $observedAt = [datetime]::UtcNow
            $script:recoveryReceipt = [ordered]@{
                schemaVersion = 1
                observedAtUtc = $observedAt.ToString('O', [cultureinfo]::InvariantCulture)
                expiresAtUtc = $observedAt.AddMinutes(15).ToString('O', [cultureinfo]::InvariantCulture)
                tenantId = $script:recoveryBackend.TenantId
                subscriptionId = $script:recoveryBackend.SubscriptionId
                storageAccountName = $script:recoveryBackend.StorageAccountName
                resourceGroupName = 'rg-fixture-state'
                containerName = $script:recoveryBackend.ContainerName
                stateKey = 'bicep-module-identities.tfstate'
                versioningEnabled = $true
                deleteRetentionEnabled = $true
                deleteRetentionDays = [long]7
                allowPermanentDelete = $false
                lifecycleManagementPolicyErrorCode = 'ManagementPolicyNotFound'
            }
            $script:recoveryReceiptPath = Join-Path $TestDrive 'state-recovery-receipt.json'
            [IO.File]::WriteAllText(
                $script:recoveryReceiptPath,
                (ConvertTo-Json -InputObject $script:recoveryReceipt -Depth 5) + "`n",
                [Text.UTF8Encoding]::new($false)
            )
            $script:bootstrap = @{
                resource_id = 'synthetic-bootstrap-resource'
                client_id = '10000000-0000-4000-8000-000000000006'
                principal_id = '10000000-0000-4000-0000-000000000007'
            }
            $script:state = @{
                lineage = '10000000-0000-4000-8000-000000000001'
                serial = [long]42
                resources = @(
                    @{
                        module = 'module.bicep["avm/ptn/lz/sub-vending"]'
                        mode = 'managed'
                        type = 'azapi_resource'
                        name = 'identity'
                        provider = 'provider["registry.terraform.io/azure/azapi"]'
                        instances = @(
                            @{
                                attributes = @{
                                    id = $script:stateSecret
                                    output = @{
                                        properties = @{
                                            clientId = '10000000-0000-4000-8000-000000000016'
                                            principalId = '10000000-0000-4000-8000-000000000017'
                                        }
                                    }
                                }
                            }
                        )
                    }
                )
            }
        }

        It 'identifies exactly one unindexed historical identity without returning its values' {
            $entry = Get-AvmBicepSubscriptionVendingStateRetirementEntry -State $script:state -BootstrapIdentity $script:bootstrap

            $entry.Address | Should -BeExactly 'module.bicep["avm/ptn/lz/sub-vending"].azapi_resource.identity'
            $entry.Lineage | Should -BeExactly '10000000-0000-4000-8000-000000000001'
            $entry.Serial | Should -Be 42
            $entry.ResourceIdDifferent | Should -BeTrue
            $entry.ClientIdDifferent | Should -BeTrue
            $entry.PrincipalIdDifferent | Should -BeTrue
            ($entry | ConvertTo-Json -Compress) | Should -Not -Match $script:stateSecret
        }

        It 'rejects ambiguous, indexed, or bootstrap-bound retirement candidates: <Case>' -ForEach @(
            @{
                Case = 'multiple instances'
                Edit = { param($state, $bootstrap) $state.resources[0].instances += $state.resources[0].instances[0].Clone() }
            }
            @{
                Case = 'indexed instance'
                Edit = { param($state, $bootstrap) $state.resources[0].instances[0].index_key = 0 }
            }
            @{
                Case = 'shared resource binding'
                Edit = { param($state, $bootstrap) $bootstrap.resource_id = $state.resources[0].instances[0].attributes.id }
            }
        ) {
            & $Edit $script:state $script:bootstrap

            { Get-AvmBicepSubscriptionVendingStateRetirementEntry -State $script:state -BootstrapIdentity $script:bootstrap } |
                Should -Throw
        }

        It 'carries complete bootstrap evidence through preparation before dry-running the exact discovered removal' {
            $values = New-AvmTestBamiSettings
            $values.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID =
                '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-avm-managed-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-avm-subscription-vending'
            $values.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID = '10000000-0000-4000-8000-000000000006'
            $values.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID = '10000000-0000-4000-0000-000000000007'
            $values.TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID = 'avm-subscription-vending'
            $values.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE =
                '/providers/Microsoft.Billing/billingAccounts/account/billingProfiles/profile/invoiceSections/section'
            Mock Resolve-AvmBicepModuleExistingIdentities {
                @{ 'avm/ptn/lz/sub-vending' = @{ name = 'bootstrap' } }
            }
            Mock Resolve-AvmSubscriptionVendingIdentity {
                param($Values)
                foreach ($name in @(
                        'TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID',
                        'TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID',
                        'TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID',
                        'TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID',
                        'TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE'
                    )) {
                    $Values[$name] | Should -BeExactly $values[$name]
                }
                $script:bootstrap
            }
            Mock Get-RepositorySyncTerraformEnvironment { @{} }
            Mock Invoke-TerraformInit {}
            Mock Invoke-RepositorySyncProcess {
                param($Command, $Arguments)
                $body = if ($Command -ceq 'terraform') {
                    $script:state
                }
                else {
                    @{ versionId = '2026-10-30T14:19:27.7550000Z' }
                }
                $standardOutput = if ($body -is [string]) { $body } else {
                    ConvertTo-Json -InputObject $body -Depth 20 -Compress
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = $standardOutput; StdErr = '' }
            }
            Mock Invoke-RepositorySyncTerraform {}

            $result = Invoke-AvmBicepSubscriptionVendingStateRetirementPreparation `
                -TerraformRoot $TestDrive -Backend $script:recoveryBackend -Values $values -Configuration @{} `
                -RecoveryReceiptPath $script:recoveryReceiptPath

            $result.Status | Should -BeExactly 'Prepared'
            $result.Address | Should -BeExactly 'module.bicep["avm/ptn/lz/sub-vending"].azapi_resource.identity'
            $result.StateVersioningEnabled | Should -BeTrue
            $result.StateDeleteRetentionDays | Should -Be 7
            $result.PreRetirementVersionId | Should -BeExactly '2026-10-30T14:19:27.7550000Z'
            ($result | ConvertTo-Json -Compress) | Should -Not -Match $script:stateSecret
            Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
                $Command -ceq 'az'
            }
            Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
                $Command -ceq 'az' -and (@($Arguments) -join '|') -ceq (
                    'storage|blob|show|--account-name|fixturestatestore|--container-name|tfstate|' +
                    '--name|bicep-module-identities.tfstate|--auth-mode|login|--subscription|' +
                    '20000000-0000-4000-8000-000000000002|--only-show-errors|--output|json|--query|{versionId:versionId}'
                )
            }
            Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
                $Command -ceq 'terraform' -and (@($Arguments) -join '|') -ceq 'state|pull'
            }
            Should -Invoke Invoke-RepositorySyncTerraform -Exactly 1 -ParameterFilter {
                $Quiet -and (@($Arguments) -join '|') -ceq (
                    'state|rm|-dry-run|-lock=true|-lock-timeout=5m|' +
                    'module.bicep["avm/ptn/lz/sub-vending"].azapi_resource.identity'
                )
            }
        }

        It 'rejects absent, stale, mismatched, or unsafe recovery-policy receipts before data-plane work: <Case>' -ForEach @(
            @{
                Case = 'absent'
                Edit = {
                    Remove-Item -LiteralPath $script:recoveryReceiptPath -Force
                }
            }
            @{
                Case = 'stale'
                Edit = {
                    $script:recoveryReceipt.observedAtUtc = [datetime]::UtcNow.AddMinutes(-31).ToString('O', [cultureinfo]::InvariantCulture)
                    $script:recoveryReceipt.expiresAtUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('O', [cultureinfo]::InvariantCulture)
                }
            }
            @{
                Case = 'subscription mismatch'
                Edit = {
                    $script:recoveryReceipt.subscriptionId = '30000000-0000-4000-8000-000000000002'
                }
            }
            @{
                Case = 'unsafe deletion policy'
                Edit = {
                    $script:recoveryReceipt.allowPermanentDelete = $true
                }
            }
            @{
                Case = 'lifecycle policy present'
                Edit = {
                    $script:recoveryReceipt.lifecycleManagementPolicyErrorCode = 'UnexpectedPolicyResult'
                }
            }
        ) {
            & $Edit
            if (Test-Path -LiteralPath $script:recoveryReceiptPath) {
                [IO.File]::WriteAllText(
                    $script:recoveryReceiptPath,
                    (ConvertTo-Json -InputObject $script:recoveryReceipt -Depth 5) + "`n",
                    [Text.UTF8Encoding]::new($false)
                )
            }
            Mock Invoke-RepositorySyncProcess {
                throw 'Data-plane work must not start for an invalid receipt.'
            }

            {
                Get-AvmBicepStateRecoveryPolicy -Backend $script:recoveryBackend -Environment @{} `
                    -ReceiptPath $script:recoveryReceiptPath
            } | Should -Throw
            Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
        }
    }

    It 'accepts both existing identities and new identities with explicitly unknown outputs' -ForEach @($true, $false) {
        $script:guard.Plan = New-AvmTestBicepIdentityPlan -KnownClient:$_
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Not -Throw
    }

    It 'accepts only the verified legacy hashed module identity transition: known outputs <_>' -ForEach @($true, $false) {
        $script:guard.Plan = New-AvmTestBicepIdentityPlan -NamingMigration -KnownClient:$_
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Not -Throw
        $previous = Assert-AvmBicepIdentityPlan @script:guard -PassThru
        $previous.Count | Should -Be 2
        $previous['avm/res/storage/storage-account'].identity_resource_id |
            Should -BeLike '*/id-avm-bicep-avm-res-storage-storage-account-3ecbb5ba'
        $previous['avm/res/storage/storage-account'].client_id | Should -BeExactly '10000000-0000-4000-8000-000000000116'
        $previous['avm/res/storage/storage-account'].Count | Should -Be 3
    }

    It 'rejects a forged old module path, hash, tenant or client during replacement: <Case>' -ForEach @(
        @{ Case = 'different module'; Edit = { param($p) $p.resource_changes[0].change.before.name = 'id-avm-bicep-avm-res-storage-storage-account-3ecbb5ba' } }
        @{ Case = 'different hash'; Edit = { param($p) $p.resource_changes[0].change.before.name = 'id-avm-bicep-avm-res-fabric-capacity-00000000' } }
        @{ Case = 'another tenant'; Edit = { param($p) $p.resource_changes[0].change.before.output.properties.tenantId = '90000000-0000-4000-8000-000000000001' } }
        @{ Case = 'shared client'; Edit = { param($p) $p.resource_changes[0].change.before.output.properties.clientId = '10000000-0000-4000-8000-000000000004' } }
        @{ Case = 'another caller'; Edit = { param($p) $p.resource_changes[3].change.before.body.properties.subject += ':untrusted' } }
    ) {
        $script:guard.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        & $Edit $script:guard.Plan
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw
    }

    It 'checks flattened-name uniqueness independently of discovery before examining a plan' {
        $script:guard.Modules = @{ 'avm/res/a-b/c' = @(); 'avm/res/a/b-c' = @() }
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw '*unique identity names*'
    }

    It 'retains staged credentials and adds the same exact registry environment subject to both module identities' {
        foreach ($module in $script:plan.planned_values.root_module.child_modules) {
            $path = [regex]::Match($module.address, '^module\.bicep\["([^"]+)"\]$').Groups[1].Value
            $credentials = @($module.resources | Where-Object { $_.values['type'] -like '*/federatedIdentityCredentials@*' })
            @($credentials.values.name | Select-Object -Unique) | Should -HaveCount 3
            $staged = @($credentials | Where-Object { $_.address.EndsWith('.azapi_resource.identity_federated_credentials["avm-validation"]') })[0]
            $staged.values.body.properties.subject | Should -BeExactly (
                'repository_owner_id:6844498:repository_id:447791597:environment:avm-validation:' +
                'job_workflow_ref:Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main:' +
                "workflow_ref:Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/heads/main"
            )
            $tools = @($credentials | Where-Object { $_.address.EndsWith('.azapi_resource.validation_federated_credential') })[0]
            $tools.values.body.properties.subject |
                Should -BeExactly 'repository_owner_id:6844498:repository_id:1239632211:environment:avm-validation'
            $registry = @($credentials | Where-Object { $_.address.EndsWith('.azapi_resource.bicep_registry_federated_credential[0]') })[0]
            $registry.values.name | Should -BeExactly ((Get-AvmBicepModuleIdentityName -ModulePath $path) + '-registry-avm-validation')
            $registry.values.body.properties.subject |
                Should -BeExactly 'repository_owner_id:6844498:repository_id:447791597:environment:avm-validation'
            $registry.values.body.properties.audiences | Should -Be @('api://AzureADTokenExchange')
            $registry.values.body.properties.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
            $registry.values.body.properties.Count | Should -Be 3
        }
    }

    It 'accepts adding only registry federation without replacing existing identities, memberships or credentials' {
        foreach ($change in $script:plan.resource_changes) {
            if ($change.address.EndsWith('.azapi_resource.bicep_registry_federated_credential[0]')) {
                $change.change.before = $null
                $change.change.actions = @('create')
            }
        }
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Not -Throw
        @($script:plan.resource_changes | Where-Object { $_.change.actions -contains 'create' }) | Should -HaveCount 2
        @($script:plan.resource_changes | Where-Object { $_.change.actions -contains 'delete' }) | Should -HaveCount 0
    }

    It 'requires every staged and current registry credential: <_>' -ForEach @(
        'identity_federated_credentials["avm-validation"]', 'validation_federated_credential', 'bicep_registry_federated_credential[0]'
    ) {
        $address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.' + $_
        $script:plan.resource_changes = @($script:plan.resource_changes | Where-Object address -CNE $address)
        $module = $script:plan.planned_values.root_module.child_modules[0]
        $module.resources = @($module.resources | Where-Object address -CNE $address)
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw '*complete dedicated repository identity*'
    }

    It 'rejects altered registry federation <Side>: <Case>' -ForEach @(
        foreach ($side in @('before', 'after', 'planned')) {
            foreach ($case in @(
                @{ Case = 'owner ID'; Edit = { param($v) $v.body.properties.subject = $v.body.properties.subject.Replace('6844498', '9999999') } }
                @{ Case = 'repository ID'; Edit = { param($v) $v.body.properties.subject = $v.body.properties.subject.Replace('447791597', '999999999') } }
                @{ Case = 'Tools credential substitution'; Edit = { param($v) $v.body.properties.subject = $v.body.properties.subject.Replace('447791597', '1239632211') } }
                @{ Case = 'environment'; Edit = { param($v) $v.body.properties.subject = $v.body.properties.subject.Replace('avm-validation', 'pr-check') } }
                @{ Case = 'issuer'; Edit = { param($v) $v.body.properties.issuer = 'https://untrusted.example' } }
                @{ Case = 'audience'; Edit = { param($v) $v.body.properties.audiences = @('different-audience') } }
                @{ Case = 'additional audience'; Edit = { param($v) $v.body.properties.audiences += 'different-audience' } }
                @{ Case = 'wildcard subject'; Edit = { param($v) $v.body.properties.subject = '*' } }
                @{ Case = 'unconfigured workflow claim'; Edit = { param($v) $v.body.properties.subject += ':job_workflow_ref:Azure/tools/.github/workflows/run.yml@refs/heads/main' } }
                @{ Case = 'flexible expression'; Edit = { param($v)
                    $v.body.properties.Remove('subject')
                    $v.body.properties.claimsMatchingExpression = @{ languageVersion = 1; value = "claims['sub'] matches '*'" }
                } }
                @{ Case = 'different API'; Edit = { param($v) $v.type = $v.type.Replace('2023-07-31-preview', '2025-01-31-preview') } }
                @{ Case = 'credential name'; Edit = { param($v) $v.name = 'shared-registry-credential' } }
                @{ Case = 'foreign identity'; Edit = { param($v) $v.parent_id = '/foreign/identity' } }
                @{ Case = 'foreign resource ID'; Edit = { param($v) $v.id = '/foreign/credential' } }
            )) {
                @{ Side = $side; Case = $case.Case; Edit = $case.Edit }
            }
        }
    ) {
        $address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.bicep_registry_federated_credential[0]'
        $values = if ($Side -ceq 'planned') {
            @($script:plan.planned_values.root_module.child_modules[0].resources | Where-Object address -CEQ $address)[0].values
        }
        else {
            @($script:plan.resource_changes | Where-Object address -CEQ $address)[0].change[$Side]
        }
        & $Edit $values
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw '*Candidate federation*'
    }

    It 'does not treat the shared registry subject as proof of an old module identity during renaming' {
        $script:guard.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        foreach ($change in $script:guard.Plan.resource_changes) {
            if ($change.address.EndsWith('.azapi_resource.identity_federated_credentials["avm-validation"]')) {
                $change.change.before = $null
                $change.change.actions = @('create')
            }
        }
        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw '*existing module federation*'
    }

    It 'does not enable registry environment federation outside the Bicep module scope' {
        {
            Assert-AvmBamiIdentityPlan -Plan $script:plan -Settings $script:settings `
                -Repository 'Azure/terraform-azurerm-avm-ptn-example-repo' -RepositoryId '1234' `
                -RepositoryOwnerId '6844498' -RepositorySyncRepositoryId '1239632211' `
                -EntraGroupNames @() -BicepRegistryFederation
        } | Should -Throw '*restricted to dedicated Bicep module identities*'
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

    It 'emits a sanitized diagnostic when rejecting an unexpected plan resource' {
        $secret = 'synthetic-secret-must-not-be-disclosed'
        $script:plan.resource_changes += @{
            address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.identity_role_assignment'
            mode = 'managed'
            type = 'azapi_resource'
            provider_name = 'registry.terraform.io/azure/azapi'
            change = @{
                actions = @('create')
                after = @{ secret = $secret }
            }
        }

        $captured = & {
            try {
                Assert-AvmBicepIdentityPlan @script:guard
            }
            catch {
                $_
            }
        } 6>&1

        $diagnostic = @($captured | Where-Object {
                $_ -is [System.Management.Automation.InformationRecord] -and
                ([string]$_.MessageData).StartsWith(
                    'Bicep plan rejection [unexpected-resource]:',
                    [System.StringComparison]::Ordinal
                )
            })
        $diagnostic | Should -HaveCount 1
        $diagnostic[0].MessageData | Should -BeExactly (
            'Bicep plan rejection [unexpected-resource]: ' +
            'address=module.bicep["avm/res/fabric/capacity"].azapi_resource.identity_role_assignment; ' +
            'mode=managed; type=azapi_resource; provider_name=registry.terraform.io/azure/azapi; actions=create.'
        )
        ($captured | Out-String) | Should -Not -Match $secret
    }

    It 'reports every rejected resource in plan order without disclosing raw values' {
        $previousAddress = 'synthetic-previous-address-must-not-be-disclosed'
        $secret = 'synthetic-secret-must-not-be-disclosed'
        $identity = $script:plan.resource_changes[0]
        $identity.previous_address = $previousAddress
        $script:plan.resource_changes += @(
            @{
                address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.identity_role_assignment'
                mode = 'managed'
                type = 'azapi_resource'
                provider_name = 'registry.terraform.io/azure/azapi'
                change = @{ actions = @('create'); after = @{ secret = $secret } }
            }
            @{
                address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.unapproved_user_assigned_identity'
                mode = 'managed'
                type = 'azapi_resource'
                provider_name = 'registry.terraform.io/azure/azapi'
                change = @{ actions = @('delete'); before = @{ secret = $secret } }
            }
        )

        $captured = & {
            try {
                Assert-AvmBicepIdentityPlan @script:guard
            }
            catch {
                $_
            }
        } 6>&1

        $diagnostics = @($captured | Where-Object {
                $_ -is [System.Management.Automation.InformationRecord] -and
                ([string]$_.MessageData).StartsWith('Bicep plan rejection [', [System.StringComparison]::Ordinal)
            } | ForEach-Object MessageData)
        $diagnostics | Should -HaveCount 3
        $diagnostics[0] | Should -BeExactly (
            'Bicep plan rejection [state-address-move]: ' +
            'address=module.bicep["avm/res/fabric/capacity"].azapi_resource.identity[0]; ' +
            'mode=managed; type=azapi_resource; provider_name=registry.terraform.io/azure/azapi; actions=no-op.'
        )
        $diagnostics[1] | Should -BeExactly (
            'Bicep plan rejection [unexpected-resource]: ' +
            'address=module.bicep["avm/res/fabric/capacity"].azapi_resource.identity_role_assignment; ' +
            'mode=managed; type=azapi_resource; provider_name=registry.terraform.io/azure/azapi; actions=create.'
        )
        $diagnostics[2] | Should -BeExactly (
            'Bicep plan rejection [unexpected-resource]: ' +
            'address=module.bicep["avm/res/fabric/capacity"].azapi_resource.unapproved_user_assigned_identity; ' +
            'mode=managed; type=azapi_resource; provider_name=registry.terraform.io/azure/azapi; actions=delete.'
        )
        ($captured | Out-String) | Should -Match 'may only manage dedicated identities'
        ($captured | Out-String) | Should -Not -Match $previousAddress
        ($captured | Out-String) | Should -Not -Match $secret
    }

    It 'continues rejecting forbidden dedicated identity and role operations: <Case>' -ForEach @(
        @{
            Case = 'user-assigned identity'
            Address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.unapproved_user_assigned_identity'
        }
        @{
            Case = 'role assignment'
            Address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.identity_role_assignment'
        }
    ) {
        $script:plan.resource_changes += @{
            address = $Address
            mode = 'managed'
            type = 'azapi_resource'
            provider_name = 'registry.terraform.io/azure/azapi'
            change = @{ actions = @('create') }
        }

        { Assert-AvmBicepIdentityPlan @script:guard } |
            Should -Throw '*may only manage dedicated identities*'
    }

    It 'allows only the exact unchanged dedicated identity state move' {
        $identity = $script:plan.resource_changes[0]
        $identity.previous_address = $identity.address.Replace('.identity[0]', '.identity')

        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Not -Throw
    }

    It 'rejects incompatible dedicated identity state moves: <Case>' -ForEach @(
        @{
            Case = 'wrong source'
            Edit = { param($change, $guard) $change.previous_address = 'module.bicep["avm/res/fabric/capacity"].azapi_resource.identity[1]' }
        }
        @{
            Case = 'wrong destination'
            Edit = { param($change, $guard) $change.address = $change.address.Replace('.identity[0]', '.identity[1]') }
        }
        @{
            Case = 'cross module'
            Edit = { param($change, $guard) $change.previous_address = 'module.bicep["avm/res/storage/storage-account"].azapi_resource.identity' }
        }
        @{
            Case = 'provider mismatch'
            Edit = { param($change, $guard) $change.provider_name = 'registry.terraform.io/example/azapi' }
        }
        @{
            Case = 'type mismatch'
            Edit = { param($change, $guard) $change.type = 'azuread_group_member' }
        }
        @{
            Case = 'non-no-op action'
            Edit = { param($change, $guard) $change.change.actions = @('update') }
        }
        @{
            Case = 'importing'
            Edit = { param($change, $guard) $change.change.importing = @{ id = 'synthetic-import-must-not-be-disclosed' } }
        }
        @{
            Case = 'external identity path'
            Edit = { param($change, $guard) $guard['ExistingIdentities'] = @{ 'avm/res/fabric/capacity' = @{ name = 'shared-identity' } } }
        }
        @{
            Case = 'changed before or after attributes'
            Edit = { param($change, $guard) $change.change.after.name = 'changed-identity-name' }
        }
    ) {
        $identity = $script:plan.resource_changes[0]
        $identity.previous_address = $identity.address.Replace('.identity[0]', '.identity')
        & $Edit $identity $script:guard

        { Assert-AvmBicepIdentityPlan @script:guard } | Should -Throw
    }

    It 'classifies state address moves without disclosing either address' {
        $secret = 'synthetic-previous-address-must-not-be-disclosed'
        $script:plan.resource_changes[0].previous_address = $secret

        $captured = & {
            try {
                Assert-AvmBicepIdentityPlan @script:guard
            }
            catch {
                $_
            }
        } 6>&1

        $diagnostic = @($captured | Where-Object {
                $_ -is [System.Management.Automation.InformationRecord] -and
                ([string]$_.MessageData).StartsWith(
                    'Bicep plan rejection [state-address-move]:',
                    [System.StringComparison]::Ordinal
                )
            })
        $diagnostic | Should -HaveCount 1
        ($captured | Out-String) | Should -Not -Match $secret
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
