BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryConfig.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    $script:config = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-config' 'config.json') | ConvertFrom-Json
}

Describe 'Configured repository Entra memberships' {
    It 'keeps the original eight-field source and five-field Bicep projection without group-ID staging fields' {
        $source = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
        $source.Count | Should -Be 8
        (Get-AvmBamiSettings -Values $source -BicepOnly).Count | Should -Be 5
        @($source.Keys | Where-Object { $_ -cmatch '(ENTRA_READERS|TEST_IDENTITY_OWNERS|FABRIC_ADMINS)_GROUP_ID' }).Count |
            Should -Be 0
    }

    It 'applies the two configured defaults and adds Fabric only to the requested repository' {
        $default = @($script:config.repositoryGroups | Where-Object name -CEQ 'default')[0]
        $default.entraGroups | Should -Be @('avm-test-entra-readers', 'avm-test-management-group-owners')
        $fabric = @($script:config.repositoryGroups | Where-Object name -CEQ 'fabric')
        $fabric.Count | Should -Be 1
        $fabric[0].repositories | Should -Be @('avm-ptn-unified-data-platform')
        $fabric[0].entraGroups | Should -Be @('avm-test-entra-fabric-admins')
        $selected = Resolve-RepositorySettings -repositoryConfig $script:config -repoId 'avm-ptn-unified-data-platform'
        $selected.EntraGroups | Should -Be @('avm-test-entra-readers', 'avm-test-management-group-owners', 'avm-test-entra-fabric-admins')
        $selected.TestTenant | Should -BeExactly 'bami'
        foreach ($repository in @('unlisted', 'avm-res-fabric-capacity', 'avm-ptn-example-repo')) {
            (Resolve-RepositorySettings -repositoryConfig $script:config -repoId $repository).EntraGroups |
                Should -Be $default.entraGroups
        }
    }

    It 'accumulates arbitrary names in ordered groups without replacing defaults or duplicating edges' {
        $config = [pscustomobject]@{ repositoryGroups = @(
            [pscustomobject]@{ name = 'late'; order = 20; repositories = @('example'); entraGroups = @('Extra testers', 'Readers') }
            [pscustomobject]@{ name = 'default'; order = -1; repositories = @('*'); entraGroups = @('Readers', 'Owners'); testTenant = 'bami' }
            [pscustomobject]@{ name = 'early'; order = 10; repositories = @('example'); entraGroups = @('Data engineering', 'Owners') }
            [pscustomobject]@{ name = 'last'; order = 20; repositories = @('example'); entraGroups = @('Last group') }
        ) }
        $selected = Resolve-RepositorySettings -repositoryConfig $config -repoId 'example'
        $selected.EntraGroups | Should -Be @('Readers', 'Owners', 'Data engineering', 'Extra testers', 'Last group')
        $selected.TestTenant | Should -BeExactly 'bami'
        (Resolve-RepositorySettings -repositoryConfig $config -repoId 'unmatched').EntraGroups |
            Should -Be @('Readers', 'Owners')
    }

    It 'allows empty and absent lists without inventing names or overriding inherited memberships' {
        $groups = @(
            @{ name = 'default'; repositories = @('*'); entraGroups = @('Readers') }
            @{ name = 'empty'; repositories = @('example'); entraGroups = @() }
            @{ name = 'absent'; repositories = @('example') }
        )
        Resolve-AvmRepositoryEntraGroups -Groups $groups -RepositoryId 'example' | Should -Be @('Readers')
        Resolve-AvmRepositoryEntraGroups -Groups @(@{ name = 'none'; repositories = @('*') }) -RepositoryId 'example' |
            Should -BeNullOrEmpty
    }

    It 'preserves exact display names, including spaces and quotes' {
        $names = @('Data engineering testers', 'A "quoted" name', 'Readers', 'Readers')
        $actual = ConvertTo-AvmEntraGroupNames -Names $names
        ($actual -is [string[]]) | Should -BeTrue
        $actual | Should -Be @('Data engineering testers', 'A "quoted" name', 'Readers')
    }

    It 'rejects invalid names or non-flat config lists even in an unmatched group' {
        foreach ($names in @($null, 'Readers', @{ bami = @('Readers') }, @(''), @(' Readers'), @("line`nbreak"), @(42), @($true))) {
            $groups = @(@{ name = 'invalid'; repositories = @('unmatched'); entraGroups = $names })
            { Resolve-AvmRepositoryEntraGroups -Groups $groups -RepositoryId 'example' } | Should -Throw
        }
    }

    It 'binds only subscription vending to the complete bootstrap-owned identity evidence' {
        $settings = New-AvmTestBamiSettings
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID =
            '/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-avm-managed-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-avm-subscription-vending'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID = '10000000-0000-4000-8000-000000000006'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID = '10000000-0000-4000-8000-000000000007'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID = 'avm-subscription-vending'
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE =
            '/providers/Microsoft.Billing/billingAccounts/account/billingProfiles/profile/invoiceSections/section'

        $vending = Resolve-RepositorySettings -repositoryConfig $script:config -repoId 'avm-ptn-alz-sub-vending'
        $vending.ExistingIdentity.name | Should -BeExactly 'id-avm-subscription-vending'
        $vending.ExistingIdentity.resourceGroupName | Should -BeExactly 'rg-avm-managed-identities'
        $vending.ExistingIdentity.manageEntraGroups | Should -BeFalse
        $vending.EntraGroups | Should -Be @(
            'avm-test-entra-readers',
            'avm-test-management-group-owners',
            'avm-test-subscription-vending-owners',
            'avm-test-management-group-iam-admins'
        )

        $resolved = Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $vending.ExistingIdentity -Values $settings
        $resolved.resource_id | Should -BeExactly $settings.TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID
        $resolved.management_group_id | Should -BeExactly 'avm-subscription-vending'
        $resolved.billing_scope | Should -BeExactly $settings.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE

        (Resolve-RepositorySettings -repositoryConfig $script:config -repoId 'avm-ptn-example-repo').ExistingIdentity |
            Should -BeNullOrEmpty
        $settings.TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE = '/providers/Microsoft.Billing/billingAccounts/account'
        { Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $vending.ExistingIdentity -Values $settings } |
            Should -Throw '*invoice-section*'
    }
}
