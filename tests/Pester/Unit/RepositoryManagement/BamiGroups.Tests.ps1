BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryConfig.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    $script:config = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-config' 'config.json') | ConvertFrom-Json
}

Describe 'Pinned BAMI repository access group bundle' {
    BeforeEach { $script:bundle = New-AvmTestBamiSettings }

    It 'requires eleven repository-sync fields without changing the eight-field source or five-field Bicep projection' {
        $repository = Get-AvmBamiSettings -Values $script:bundle -RepositorySync
        $repository.Count | Should -Be 11
        (Get-AvmBamiSettings -Values $repository).Count | Should -Be 8
        (Get-AvmBamiSettings -Values $repository -BicepOnly).Count | Should -Be 5
        { Get-AvmBamiSettings -Values $repository -RepositorySync -BicepOnly } | Should -Throw '*separate projections*'
    }

    It 'rejects every missing repository-sync field' {
        foreach ($key in @($script:bundle.Keys)) {
            $partial = $script:bundle.Clone()
            $partial.Remove($key)
            { Get-AvmBamiSettings -Values $partial -RepositorySync } | Should -Throw
        }
    }

    It 'requires nonempty GUID object IDs rather than group names or resource IDs' {
        foreach ($key in @('TEST_BAMI_ENTRA_READERS_GROUP_ID', 'TEST_BAMI_TEST_IDENTITY_OWNERS_GROUP_ID', 'TEST_BAMI_FABRIC_ADMINS_GROUP_ID')) {
            foreach ($value in @('avm-test-entra-readers', '/groups/example', [guid]::Empty.ToString(), '', $null, 42)) {
                $invalid = $script:bundle.Clone()
                $invalid[$key] = $value
                { Get-AvmBamiSettings -Values $invalid -RepositorySync } | Should -Throw '*nonempty GUID*'
            }
        }
    }

    It 'normalizes group GUID casing and prevents any two access groups sharing an ID' {
        $script:bundle.TEST_BAMI_ENTRA_READERS_GROUP_ID = 'ABCDEFAB-0000-4000-8000-000000000008'
        (Get-AvmBamiSettings -Values $script:bundle -RepositorySync).TEST_BAMI_ENTRA_READERS_GROUP_ID |
            Should -BeExactly 'abcdefab-0000-4000-8000-000000000008'
        foreach ($key in @('TEST_BAMI_TEST_IDENTITY_OWNERS_GROUP_ID', 'TEST_BAMI_FABRIC_ADMINS_GROUP_ID')) {
            $invalid = $script:bundle.Clone()
            $invalid[$key] = $invalid.TEST_BAMI_ENTRA_READERS_GROUP_ID.ToLowerInvariant()
            { Get-AvmBamiSettings -Values $invalid -RepositorySync } | Should -Throw '*must be distinct*'
        }
    }
}

Describe 'Explicit repository Fabric admin API capability' {
    It 'defaults off without inferring permissions from module names, topics, or BAMI selection' {
        $config = [pscustomobject]@{ repositoryGroups = @(
            [pscustomobject]@{ name = 'fabric'; repositories = @('*'); topics = @('fabric'); testTenant = 'bami' }
        ) }
        foreach ($repository in @('unlisted', 'avm-res-fabric-capacity', 'avm-ptn-unified-data-platform')) {
            (Resolve-RepositorySettings -repositoryConfig $config -repoId $repository).TestCapabilities.fabricAdminApis |
                Should -BeFalse
        }
        (Resolve-RepositorySettings -repositoryConfig $script:config -repoId 'unlisted').TestCapabilities.fabricAdminApis |
            Should -BeFalse
    }

    It 'requires explicit repository selection and supports ordered revocation independently of tenant selection' {
        $config = [pscustomobject]@{ repositoryGroups = @(
            [pscustomobject]@{ name = 'default'; order = -1; repositories = @('*'); testTenant = 'bami' }
            [pscustomobject]@{ name = 'fabric'; order = 10; repositories = @('avm-ptn-example-repo'); testCapabilities = @{ fabricAdminApis = $true } }
            [pscustomobject]@{ name = 'revoke'; order = 20; repositories = @('avm-ptn-example-repo'); testCapabilities = @{ fabricAdminApis = $false } }
        ) }
        (Resolve-RepositorySettings -repositoryConfig $config -repoId 'avm-ptn-example-repo').TestCapabilities.fabricAdminApis |
            Should -BeFalse
        $config.repositoryGroups = $config.repositoryGroups[0..1]
        $selected = Resolve-RepositorySettings -repositoryConfig $config -repoId 'avm-ptn-example-repo'
        $selected.TestCapabilities.fabricAdminApis | Should -BeTrue
        $selected.TestTenant | Should -BeExactly 'bami'
        (Resolve-RepositorySettings -repositoryConfig $config -repoId 'avm-ptn-unlisted').TestCapabilities.fabricAdminApis |
            Should -BeFalse
    }

    It 'uses declaration order for equal-priority explicit capability settings' {
        $groups = @(
            @{ name = 'on'; repositories = @('avm-ptn-example-repo'); testCapabilities = @{ fabricAdminApis = $true } }
            @{ name = 'off'; repositories = @('avm-ptn-example-repo'); testCapabilities = @{ fabricAdminApis = $false } }
        )
        (Resolve-AvmRepositoryTestCapabilities -Groups $groups -RepositoryId 'avm-ptn-example-repo').fabricAdminApis |
            Should -BeFalse
        $groups[1].testCapabilities = @{}
        (Resolve-AvmRepositoryTestCapabilities -Groups $groups -RepositoryId 'avm-ptn-example-repo').fabricAdminApis |
            Should -BeTrue
    }

    It 'rejects wildcard or noncanonical grants even in an unmatched group' {
        foreach ($selectors in @(@('*'), @('*', 'avm-ptn-example-repo'), @('AVM-ptn-example'), @('Azure/terraform-azure-avm-ptn-example'), @('example'))) {
            $groups = @(@{ name = 'invalid'; repositories = $selectors; testCapabilities = @{ fabricAdminApis = $true } })
            { Resolve-AvmRepositoryTestCapabilities -Groups $groups -RepositoryId 'avm-ptn-unmatched' } |
                Should -Throw '*explicit canonical repository IDs*'
        }
    }

    It 'rejects unsupported capability keys and nonboolean values without coercion' {
        foreach ($capabilities in @($null, 'fabric', @{ unknown = $true }, @{ FabricAdminApis = $true },
                @{ fabricAdminApis = 'true' }, @{ fabricAdminApis = 1 }, @{ fabricAdminApis = $null }, @{ fabricAdminApis = @($true) })) {
            $groups = @(@{ name = 'invalid'; repositories = @('avm-ptn-example-repo'); testCapabilities = $capabilities })
            { Resolve-AvmRepositoryTestCapabilities -Groups $groups -RepositoryId 'avm-ptn-unmatched' } | Should -Throw
        }
    }
}
