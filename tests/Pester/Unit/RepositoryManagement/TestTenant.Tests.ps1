BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'shared' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryConfig.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
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

    It 'validates the checked-in configuration and its BAMI default for unlisted repositories' {
        $default = @($script:config.repositoryGroups | Where-Object name -EQ 'default')
        $default | Should -HaveCount 1
        $default[0].repositories | Should -Be @('*')
        $default[0].testTenant | Should -BeExactly 'bami'
        (Resolve-RepositorySettings -repositoryConfig $script:config -repoId 'unlisted-repository').TestTenant |
            Should -BeExactly 'bami'
        & (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Test-RepositoryConfig.ps1')
    }

    It 'inherits the BAMI default while allowing an explicit higher-order legacy exception' {
        $config = [pscustomobject]@{
            repositoryGroups = @(
                [pscustomobject]@{ name = 'default'; order = -1; repositories = @('*'); testTenant = 'bami' }
                [pscustomobject]@{ name = 'files'; order = 20; repositories = @('exception'); managedFiles = @('overlay') }
                [pscustomobject]@{ name = 'legacy'; order = 5; repositories = @('exception'); testTenant = 'legacy' }
            )
        }
        (Resolve-RepositorySettings -repositoryConfig $config -repoId 'exception').TestTenant | Should -BeExactly 'legacy'
        (Resolve-RepositorySettings -repositoryConfig $config -repoId 'unlisted').TestTenant | Should -BeExactly 'bami'
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
        $config = [pscustomobject]@{
            repositoryGroups = @(
                [pscustomobject]@{
                    name = 'default'; order = -1; repositories = @('*'); testTenant = 'legacy'
                    teams = @([pscustomobject]@{ name = 'maintainers'; repositoryPermission = 'push'; environmentApproval = $true })
                    topics = @('shared')
                    codeOwnersFileProtectionTeams = @('maintainers')
                    workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
                        jobWorkflowRef = 'Azure/example/.github/workflows/test.yml@refs/heads/main'
                    }
                }
                [pscustomobject]@{
                    name = 'specific'; order = 10; repositories = @('example')
                    topics = @('specific')
                    codeOwnersTeams = @('maintainers')
                    pullRequestBypassTeams = @('maintainers')
                    workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
                        jobWorkflowRef = 'Azure/example/.github/workflows/test.yml@refs/heads/release'
                    }
                }
            )
        }
        $before = Resolve-RepositorySettings -repositoryConfig $config -repoId 'example'
        $config.repositoryGroups[0].testTenant = 'bami'
        $after = Resolve-RepositorySettings -repositoryConfig $config -repoId 'example'
        $before.TestTenant | Should -BeExactly 'legacy'
        $after.TestTenant | Should -BeExactly 'bami'
        foreach ($key in @(
            'RepositoryGroupNames', 'Teams', 'Topics', 'CodeOwnersDefaultTeams',
            'CodeOwnersFileProtectionTeams', 'PullRequestBypassTeams',
            'WorkloadIdentityFederationSubjectClaimOverrides'
        )) {
            (ConvertTo-Json -InputObject $after[$key] -Depth 10 -Compress) |
                Should -BeExactly (ConvertTo-Json -InputObject $before[$key] -Depth 10 -Compress)
        }
        $after.WorkloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef |
            Should -BeExactly 'Azure/example/.github/workflows/test.yml@refs/heads/release'
    }

    It 'does not change the authoring module managed-file group resolution' {
        $config = [pscustomobject]@{
            repositoryGroups = @(
                [pscustomobject]@{ name = 'default'; order = -1; repositories = @('*'); testTenant = 'legacy'; managedFiles = @('root') }
                [pscustomobject]@{ name = 'files'; order = 20; repositories = @('example'); managedFiles = @('overlay') }
            )
        }
        $module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -PassThru
        $before = & $module {
            param($Config)
            (Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $Config -RepoId 'example').FileGroups
        } $config
        $config.repositoryGroups[0].testTenant = 'bami'
        $after = & $module {
            param($Config)
            (Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $Config -RepoId 'example').FileGroups
        } $config
        $before | Should -Be @('root', 'overlay')
        $after | Should -Be $before
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

    It 'preserves optional tags and original ordering from a native or JSON inventory: <AsJson>' -ForEach @(
        @{ AsJson = $false }
        @{ AsJson = $true }
    ) {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = 'Azure Local'
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[1].tag = 'General'
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS = @($script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[27..0])
        $before = ConvertTo-Json -InputObject $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS -Depth 5 -Compress
        if ($AsJson) { $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS = $before }

        $all = Get-AvmBamiSettings -Values $script:bundle
        $execution = Get-AvmBamiSettings -Values $all -BicepOnly
        $execution.TEST_BAMI_SUBSCRIPTION_IDS | Should -BeExactly $all.TEST_BAMI_SUBSCRIPTION_IDS
        $pool = ConvertFrom-AvmTestTenantJson -Json $execution.TEST_BAMI_SUBSCRIPTION_IDS
        $expected = ConvertFrom-AvmTestTenantJson -Json $before
        $pool | Should -HaveCount 28
        $pool.id | Should -Be $expected.id
        $pool.name | Should -Be $expected.name
        $pool[27].tag | Should -BeExactly 'Azure Local'
        $pool[26].tag | Should -BeExactly 'General'
        foreach ($entry in $pool[0..25]) {
            $entry.Contains('tag') | Should -BeFalse
            $entry.Count | Should -Be 2
        }
        (Get-AvmBamiSettings -Values $all).TEST_BAMI_SUBSCRIPTION_IDS |
            Should -BeExactly $all.TEST_BAMI_SUBSCRIPTION_IDS
    }

    It 'does not add tags or change the existing untagged JSON representation' {
        $expected = ConvertTo-Json -InputObject @(
            $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS | ForEach-Object {
                [ordered]@{ name = $_.name; id = $_.id }
            }
        ) -Compress
        (Get-AvmBamiSettings -Values $script:bundle).TEST_BAMI_SUBSCRIPTION_IDS |
            Should -BeExactly $expected
    }

    It 'rejects an explicitly malformed tag rather than treating it as General: <Case>' -ForEach @(
        @{ Case = 'null'; Value = $null }
        @{ Case = 'empty'; Value = '' }
        @{ Case = 'whitespace'; Value = ' ' }
        @{ Case = 'leading whitespace'; Value = ' General' }
        @{ Case = 'trailing whitespace'; Value = 'General ' }
        @{ Case = 'control character'; Value = "Azure`nLocal" }
        @{ Case = 'delete character'; Value = "Azure$([char]127)Local" }
        @{ Case = 'underscore'; Value = 'Azure_Local' }
        @{ Case = 'repeated separators'; Value = 'Azure  Local' }
        @{ Case = 'mixed separators'; Value = 'Azure -Local' }
        @{ Case = 'trailing hyphen'; Value = 'Azure-Local-' }
        @{ Case = 'non-ASCII'; Value = "Azure$([char]233)" }
        @{ Case = 'too long'; Value = ('A' * 65) }
        @{ Case = 'boolean'; Value = $true }
        @{ Case = 'number'; Value = 1 }
        @{ Case = 'array'; Value = @('General') }
        @{ Case = 'object'; Value = @{ name = 'General' } }
    ) {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = $Value
        foreach ($bicepOnly in @($false, $true)) {
            { Get-AvmBamiSettings -Values $script:bundle -BicepOnly:$bicepOnly } |
                Should -Throw '*subscription tag must be*'
        }
    }

    It 'still rejects unsupported properties and duplicate or case-colliding JSON tags' {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = 'Azure Local'
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].extra = 'unsupported'
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*only an optional tag field*'
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].Remove('extra')
        $json = ConvertTo-Json -InputObject $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS -Depth 5 -Compress
        foreach ($field in @('tag', 'Tag')) {
            $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS = $json.Replace(
                '"tag":"Azure Local"', ('"tag":"Azure Local","' + $field + '":"General"')
            )
            { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*Invalid test tenant JSON*'
        }
    }

    It 'accepts a tag at the 64-character limit without changing its spelling' {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = 'A' * 64
        $pool = ConvertFrom-AvmTestTenantJson -Json (Get-AvmBamiSettings -Values $script:bundle).TEST_BAMI_SUBSCRIPTION_IDS
        $pool[0].tag | Should -BeExactly ('A' * 64)
    }

    It 'rejects unknown properties that shadow dictionary members: <Field>' -ForEach @(
        @{ Field = 'Count'; Value = 3 }
        @{ Field = 'Keys'; Value = @('name', 'id', 'tag') }
    ) {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = 'Azure Local'
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0][$Field] = $Value
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*only an optional tag field*'
    }

    It 'rejects a miscased Tag property in native and JSON inventories' -ForEach @($false, $true) {
        $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS[0].Tag = 'Azure Local'
        if ($_) {
            $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS = ConvertTo-Json -InputObject $script:bundle.TEST_BAMI_SUBSCRIPTION_IDS -Compress
        }
        { Get-AvmBamiSettings -Values $script:bundle } | Should -Throw '*only an optional tag field*'
    }

    It 'rejects each missing field rather than falling back to legacy settings' {
        foreach ($key in @((Get-AvmBamiSettings -Values $script:bundle).Keys)) {
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

    Describe 'General BAMI test subscription selection' {
        It 'keeps all legacy untagged subscriptions in their original order' {
            $settings = New-AvmTestBamiSettings
            $pool = @(Get-AvmGeneralTestSubscription -Settings $settings)
            $pool | Should -HaveCount 28
            $pool.id | Should -Be $settings.TEST_BAMI_SUBSCRIPTION_IDS.id
            @($pool | Where-Object { $_.Contains('tag') }) | Should -HaveCount 0
        }

        It 'excludes every non-General tag before selecting the default without changing the full inventory' {
            $settings = New-AvmTestBamiSettings
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = 'Azure Local'
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[1].tag = 'General'
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[3].tag = 'Another reserved workload'
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[4].tag = 'general'
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[5].tag = 'GENERAL'
            $before = ConvertTo-Json -InputObject $settings -Depth 5 -Compress
            $pool = @(Get-AvmGeneralTestSubscription -Settings $settings)
            $pool | Should -HaveCount 24
            $pool[0].id | Should -BeExactly $settings.TEST_BAMI_SUBSCRIPTION_IDS[1].id
            $pool.id | Should -Be $settings.TEST_BAMI_SUBSCRIPTION_IDS[@(1, 2) + (6..27)].id
            (ConvertTo-Json -InputObject $settings -Depth 5 -Compress) | Should -BeExactly $before
        }

        It 'returns a single General subscription without broadening an otherwise reserved pool' {
            $settings = New-AvmTestBamiSettings
            foreach ($entry in $settings.TEST_BAMI_SUBSCRIPTION_IDS) { $entry.tag = 'Azure Local' }
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[20].tag = 'General'
            $pool = @(Get-AvmGeneralTestSubscription -Settings $settings)
            $pool | Should -HaveCount 1
            $pool[0].id | Should -BeExactly $settings.TEST_BAMI_SUBSCRIPTION_IDS[20].id
        }

        It 'rejects a fully reserved pool instead of falling back to its first entry' {
            $settings = New-AvmTestBamiSettings
            foreach ($entry in $settings.TEST_BAMI_SUBSCRIPTION_IDS) { $entry.tag = 'Azure Local' }
            { Get-AvmGeneralTestSubscription -Settings $settings } | Should -Throw '*at least one General*'
        }

        It 'validates reserved entries and the complete inventory before filtering' {
            $settings = New-AvmTestBamiSettings
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = 'Azure Local'
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[0].id = $settings.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
            { Get-AvmGeneralTestSubscription -Settings $settings } | Should -Throw '*Persistent*test pool*'
            $settings = New-AvmTestBamiSettings
            $settings.TEST_BAMI_SUBSCRIPTION_IDS[0].tag = $null
            { Get-AvmGeneralTestSubscription -Settings $settings } | Should -Throw '*subscription tag must be*'
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
