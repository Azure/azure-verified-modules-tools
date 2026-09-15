BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryConfig.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    $script:pathsJson = '["avm/res/dev-test-lab/lab"]'
    $script:config = Get-Content -Raw (Join-Path $script:root 'repository-management' 'repository-config' 'config.json') | ConvertFrom-Json
}

Describe 'Central test tenant group resolution' {
    It 'defaults missing configuration to legacy without altering existing settings' {
        $config = [pscustomobject]@{
            repositoryGroups = @([pscustomobject]@{
                name = 'default'; repositories = @('*')
                teams = @([pscustomobject]@{ name = 'maintainers' })
                topics = @('avm')
            })
        }
        $result = Resolve-RepositorySettings -repositoryConfig $config -repoId 'unlisted'
        $result.TestTenant | Should -BeExactly 'legacy'
        $result.Teams.name | Should -Be 'maintainers'
        $result.Topics | Should -Be @('avm')
    }

    It 'selects the existing ten canaries without changing their membership or orders' {
        $ring0 = $script:config.repositoryGroups | Where-Object name -EQ 'canary-ring-0'
        $ring1 = $script:config.repositoryGroups | Where-Object name -EQ 'canary-ring-1'
        $ring0.order | Should -Be 20
        $ring1.order | Should -Be 10
        $ring0.repositories | Should -Be @('avm-ptn-example-repo')
        $ring1.repositories | Should -Be @(
            'avm-ptn-example-repo', 'avm-res-devopsinfrastructure-pool', 'avm-res-network-virtualnetwork',
            'avm-res-documentdb-databaseaccount', 'avm-res-app-managedenvironment', 'avm-res-documentdb-mongocluster',
            'avm-res-compute-disk', 'avm-res-dbformysql-flexibleserver', 'avm-res-cdn-profile', 'avm-res-avs-privatecloud'
        )
        foreach ($repo in $ring1.repositories) {
            (Resolve-RepositorySettings -repositoryConfig $script:config -repoId $repo).TestTenant | Should -BeExactly 'bami'
        }
        foreach ($repo in @('avm-res-keyvault-vault', 'avm-ptn-alz', 'unlisted')) {
            (Resolve-RepositorySettings -repositoryConfig $script:config -repoId $repo).TestTenant | Should -BeExactly 'legacy'
        }
    }

    It 'uses higher order then later declaration independently of managed files' {
        $groups = @(
            @{ name = 'high'; order = 20; repositories = @('example'); testTenant = 'legacy'; managedFiles = @('ring0') }
            @{ name = 'default'; order = -1; repositories = @('*'); testTenant = 'legacy' }
            @{ name = 'low'; order = 10; repositories = @('example'); testTenant = 'bami' }
            @{ name = 'last'; order = 20; repositories = @('example'); testTenant = 'bami' }
        )
        (Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty repositories -Item example) | Should -BeExactly 'bami'
        $groups[3].Remove('testTenant')
        (Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty repositories -Item example) | Should -BeExactly 'legacy'
        $groups[0].managedFiles = @('different')
        (Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty repositories -Item example) | Should -BeExactly 'legacy'
    }

    It 'rejects every unsupported explicit value, including on a nonmatching group' {
        foreach ($value in @('BAMI', 'Legacy', '', 'candidate-2', 'bami-v1', $null, $true, 1, @('bami'), @{ name = 'bami' })) {
            $groups = @(@{ name = 'invalid'; repositories = @('other'); testTenant = $value })
            { Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty repositories -Item example } |
                Should -Throw '*exactly*legacy*bami*'
        }
    }

    It 'preserves teams, topics, CODEOWNERS and workflow-ref precedence' {
        $result = Resolve-RepositorySettings -repositoryConfig $script:config -repoId 'avm-ptn-example-repo'
        $result.RepositoryGroupNames | Should -Be @('default', 'canary-ring-0', 'canary-ring-1', 'azure-verified-modules-tier-1')
        $result.Topics | Should -Be @('azure-verified-modules', 'avm', 'canary', 'avm-tier-1')
        $result.CodeOwnersDefaultTeams | Should -Be @('azure-verified-modules-engineering-owners')
        $result.Teams.Count | Should -Be 3
        $result.WorkloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef |
            Should -Be 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main'
        & (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Test-RepositoryConfig.ps1')
    }

    It 'does not change the authoring module managed-file group resolution' {
        $module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -PassThru
        $groups = & $module {
            param($Config)
            (Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $Config -RepoId 'avm-ptn-example-repo').FileGroups
        } $script:config
        $groups | Should -Be @('root', 'canary-ring-1', 'canary-ring-0')
    }
}

Describe 'Tools-owned Bicep configuration' {
    BeforeEach {
        $script:bicep = Get-Content -Raw (Join-Path $script:root 'repository-management' 'bicep-test-tenant-config' 'config.json') |
            ConvertFrom-Json -AsHashtable
    }

    It 'compiles only the lab canary as a JSON array' {
        ConvertTo-AvmBicepModulePaths -Configuration $script:bicep | Should -BeExactly $script:pathsJson
    }

    It 'shares group order and declaration precedence' {
        $script:bicep.moduleGroups += @{ name = 'higher'; order = 20; modules = @('avm/res/dev-test-lab/lab'); testTenant = 'legacy' }
        ConvertTo-AvmBicepModulePaths -Configuration $script:bicep | Should -BeExactly '[]'
        $script:bicep.moduleGroups += @{ name = 'later'; order = 20; modules = @('avm/res/dev-test-lab/lab'); testTenant = 'bami' }
        ConvertTo-AvmBicepModulePaths -Configuration $script:bicep | Should -BeExactly $script:pathsJson
    }

    It 'deduplicates selected paths and omits every resolved legacy path' {
        $script:bicep.moduleGroups += @(
            @{ name = 'more'; order = 10; modules = @('avm/res/storage/storage-account', 'avm/res/dev-test-lab/lab'); testTenant = 'bami' }
            @{ name = 'legacy'; modules = @('avm/res/network/virtual-network'); testTenant = 'legacy' }
        )
        ConvertTo-AvmBicepModulePaths -Configuration $script:bicep |
            Should -BeExactly '["avm/res/dev-test-lab/lab","avm/res/storage/storage-account"]'
    }

    It 'rejects additional settings and nested or wildcard canary selectors' {
        foreach ($key in @('teams', 'managedFiles', 'profile', 'subscription')) {
            $changed = $script:bicep | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $changed.moduleGroups[1][$key] = @()
            { ConvertTo-AvmBicepModulePaths -Configuration $changed } | Should -Throw '*only name*'
        }
        foreach ($path in @('avm/res/dev-test-lab/lab/.test', 'avm/res/dev-test-lab/*', '*', 'AVM/res/dev-test-lab/lab')) {
            $script:bicep.moduleGroups[1].modules = @($path)
            { ConvertTo-AvmBicepModulePaths -Configuration $script:bicep } | Should -Throw
        }
    }
}

Describe 'Complete BAMI input bundle' {
    BeforeEach { $script:bundle = New-AvmTestBamiSettings }

    It 'normalizes exactly eight source fields or five execution fields' {
        $all = Get-AvmBamiSettings -Values $script:bundle
        $all.Count | Should -Be 8
        $execution = Get-AvmBamiSettings -Values $all -BicepOnly
        $execution.Count | Should -Be 5
        $execution.Keys | Should -Not -Contain 'TEST_BAMI_CONTROLLER_CLIENT_ID'
        $execution.Keys | Should -Not -Contain 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID'
        $execution.Keys | Should -Not -Contain 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'
        ($execution.TEST_BAMI_SUBSCRIPTION_IDS | ConvertFrom-Json).Count | Should -Be 28
        @($execution.Values | Where-Object { $_ -isnot [string] }).Count | Should -Be 0
    }

    It 'rejects each missing field rather than falling back to legacy settings' {
        foreach ($key in @($script:bundle.Keys)) {
            $partial = $script:bundle.Clone()
            $partial.Remove($key)
            { Get-AvmBamiSettings -Values $partial } | Should -Throw
        }
    }

    It 'excludes Persistent from a still-unique 28-subscription pool in both modes' {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].id = $script:bundle.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS.Count | Should -Be 28
        @($script:bundle.TEST_BAMI_SUBSCRIPTION_IDS.id | Select-Object -Unique).Count | Should -Be 28
        foreach ($bicepOnly in @($false, $true)) {
            { Get-AvmBamiSettings -Values $script:bundle -BicepOnly:$bicepOnly } |
                Should -Throw '*Persistent*test pool*'
        }
    }

    It 'excludes Admin from the full pool and keeps Admin separate from Persistent' {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].id = $script:bundle.TEST_BAMI_ADMIN_SUBSCRIPTION_ID
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*administration*test pool*'
        $script:bundle = New-AvmTestBamiSettings
        $script:bundle.TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $script:bundle.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*administration*Persistent*different*'
    }

    It 'rejects malformed GUIDs, group resource IDs and shared controller identity' {
        foreach ($key in @('TEST_BAMI_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID',
                'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID')) {
            $invalid = $script:bundle.Clone()
            $invalid[$key] = [guid]::Empty.ToString()
            { Get-AvmBamiSettings -Values $invalid } | Should -Throw '*nonempty GUID*'
        }
        $script:bundle.TEST_BAMI_BICEP_CLIENT_ID = $script:bundle.TEST_BAMI_CONTROLLER_CLIENT_ID
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*separate identities*'
        $script:bundle = New-AvmTestBamiSettings
        $script:bundle.TEST_BAMI_MANAGEMENT_GROUP_ID = '/providers/Microsoft.Management/managementGroups/example'
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*not a resource ID*'
    }

    It 'rejects wrong pool sizes, duplicate names or IDs, and invalid entry types' {
        foreach ($size in @(0, 1, 27, 29)) {
            $invalid = New-AvmTestBamiSettings
            $invalid.TEST_BAMI_SUBSCRIPTION_IDS = @($invalid.TEST_BAMI_SUBSCRIPTION_IDS | Select-Object -First $size)
            if ($size -eq 29) { $invalid.TEST_BAMI_SUBSCRIPTION_IDS += @{ name = 'extra'; id = [guid]::NewGuid().ToString() } }
            { Get-AvmBamiSettings -Values $invalid } | Should -Throw '*exactly 28*'
        }
        foreach ($field in @('name', 'id')) {
            $invalid = New-AvmTestBamiSettings
            $invalid.TEST_BAMI_SUBSCRIPTION_IDS[1][$field] = $invalid.TEST_BAMI_SUBSCRIPTION_IDS[0][$field]
            { Get-AvmBamiSettings -Values $invalid } | Should -Throw '*unique*'
        }
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0] = 'not-an-object'
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw
    }
}

Describe 'Bicep module-path array validation' {
    It 'keeps missing and empty arrays inactive without scalar unrolling' {
        foreach ($json in @('', '  ', '[]')) {
            $paths = ConvertFrom-AvmBicepModulePaths -Json $json
            $paths -is [string[]] | Should -BeTrue
            $paths.Count | Should -Be 0
        }
    }

    It 'preserves single and multiple canonical module paths as arrays' {
        $paths = ConvertFrom-AvmBicepModulePaths -Json $script:pathsJson
        $paths -is [string[]] | Should -BeTrue
        $paths.Count | Should -Be 1
        $paths[0] | Should -BeExactly 'avm/res/dev-test-lab/lab'
        $paths | Should -Not -Contain 'avm/res/network/virtual-network'
        $paths = ConvertFrom-AvmBicepModulePaths -Json '["avm/res/dev-test-lab/lab","avm/res/storage/storage-account"]'
        $paths.Count | Should -Be 2
    }

    It 'rejects non-array shapes, invalid entries and duplicates' {
        foreach ($json in @(
                '{}', 'null', 'invalid', 'true', '42', '"avm/res/dev-test-lab/lab"',
                '[true]', '[null]', '[{}]', '[[]]',
                '{"default":"legacy","modules":{}}',
                '["avm/res/dev-test-lab/lab","avm/res/dev-test-lab/lab"]'
            )) {
            { ConvertFrom-AvmBicepModulePaths -Json $json } | Should -Throw
        }
    }

    It 'rejects descendants, traversal, absolute and noncanonical array entries' {
        foreach ($path in @(
                '/avm/res/dev-test-lab/lab', 'C:\avm\res\dev-test-lab\lab', 'avm\res\dev-test-lab\lab',
                'avm/res/dev-test-lab/lab/../other', 'avm/res/dev-test-lab/lab/.test',
                'avm/res/dev-test-lab/lab//test', 'AVM/res/dev-test-lab/lab', 'avm/res/dev-test-lab',
                'avm/res/dev-test-lab/lab/', 'avm/res/dev-test-lab/*'
            )) {
            { ConvertFrom-AvmBicepModulePaths -Json (ConvertTo-Json -InputObject @($path) -Compress) } | Should -Throw
        }
    }
}
