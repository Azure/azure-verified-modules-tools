BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:driver = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositoryStateMigration.ps1'
    $lib = Join-Path (Split-Path $script:driver) 'lib'
    . (Join-Path $lib 'Logging.ps1')
    . (Join-Path $lib 'TestTenant.ps1')
    . (Join-Path $lib 'StateMigration.ps1')
    . (Join-Path $lib 'StateMigrationStorage.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'RepositoryState.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -PassThru
}

Describe 'Repository migration ownership guards' -Tag Component {
    BeforeEach {
        $script:pair = New-AvmTestMigrationStatePair
        $script:scope = Get-RepositoryMigrationScope -Backend $script:pair.Backend -Settings $script:pair.Settings `
            -RepoId 'avm-ptn-example-repo' -Repository $script:pair.GitHubRepository -RepositorySyncRepositoryId '5678'
    }

    It 'accepts complete federation and retains both obsolete permission owners' {
        Assert-RepositoryMigrationOwnership -Scope $script:scope -State $script:pair.Source -Identity $script:pair.Identity -Module 'module.azure'
        $script:pair.Source.resources.name | Should -Contain 'example'
        $script:pair.Source.resources.name | Should -Contain 'identity_role_assignment'
    }

    It 'rejects unsafe original ownership: <Case>' -ForEach @(
        @{ Case = 'tenant' }, @{ Case = 'subscription' }, @{ Case = 'controller client' }
        @{ Case = 'provider alias' }, @{ Case = 'namespace' }, @{ Case = 'missing federation' }
        @{ Case = 'wrong federation repository' }, @{ Case = 'wrong validation repository' }
        @{ Case = 'wrong issuer' }, @{ Case = 'extra audience' }, @{ Case = 'foreign member' }
        @{ Case = 'foreign role' }, @{ Case = 'duplicate owner' }, @{ Case = 'wrong resource group' }
    ) {
        $state = $script:pair.Source
        $identity = $state.resources[0].instances[0].attributes
        $federation = @($state.resources | Where-Object name -CEQ 'identity_federated_credentials')[0]
        $validation = @($state.resources | Where-Object name -CEQ 'validation_federated_credential')[0]
        switch ($Case) {
            'tenant' { $identity.output.value.properties.tenantId = [guid]::NewGuid().ToString() }
            'subscription' { $identity.id = $identity.id.Replace($script:scope.SubscriptionId, [guid]::NewGuid().ToString()) }
            'controller client' { $identity.output.value.properties.clientId = $script:scope.ControllerClientId }
            'provider alias' { $state.resources[0].provider += '.other' }
            'namespace' { $state.resources[0].module = 'module.azure[0]' }
            'missing federation' { $federation.instances = @($federation.instances | Select-Object -Skip 1) }
            'wrong federation repository' { $federation.instances[0].attributes.body.value.properties.subject = 'repository_owner_id:6844498:repository_id:9999:environment:pr-check:job_workflow_ref:wrong' }
            'wrong validation repository' { $validation.instances[0].attributes.body.value.properties.subject = 'repository_owner_id:6844498:repository_id:1234:environment:avm-validation' }
            'wrong issuer' { $federation.instances[0].attributes.body.value.properties.issuer = 'https://example.invalid' }
            'extra audience' { $federation.instances[0].attributes.body.value.properties.audiences += 'another-audience' }
            'foreign member' { $state.resources[2].instances[0].attributes.member_object_id = [guid]::NewGuid().ToString() }
            'foreign role' { $state.resources[3].instances[0].attributes.body.properties.principalId = [guid]::NewGuid().ToString() }
            'duplicate owner' { $state.resources += $state.resources[2] }
            'wrong resource group' { $identity.id = $identity.id.Replace('rg-bami-test', 'different-group') }
        }
        { Assert-RepositoryMigrationOwnership -Scope $script:scope -State $state -Identity $script:pair.Identity -Module 'module.azure' } |
            Should -Throw
    }

    It 'rejects aliases and foreign GitHub scope: <Case>' -ForEach @(
        @{ Case = 'alias' }, @{ Case = 'owner' }, @{ Case = 'fork' }, @{ Case = 'invalid repository id' }
    ) {
        $repository = $script:pair.GitHubRepository
        switch ($Case) {
            'alias' { $repository.full_name += '-renamed' }
            'owner' { $repository.owner.login = 'Other' }
            'fork' { $repository.fork = $true }
            'invalid repository id' { $repository.id = 0 }
        }
        { Get-RepositoryMigrationScope -Backend $script:pair.Backend -Settings $script:pair.Settings `
                -RepoId 'avm-ptn-example-repo' -Repository $repository -RepositorySyncRepositoryId '5678' } | Should -Throw '*canonical repository*'
    }

    It 'rejects duplicate JSON fields without echoing or losing their private values' {
        $path = Join-Path $TestDrive 'invalid.tfstate'
        [IO.File]::WriteAllText($path, '{"version":4,"version":4,"private":"synthetic-secret"}')
        { Read-TransferImage $path } | Should -Throw '*Invalid private state JSON*'
        { Read-RepositoryMigrationRecord $path } | Should -Throw '*contents are not logged*'
        { ConvertFrom-TransferJson '{"outputs":{"secret":"first","secret":"second"}}' } |
            Should -Throw '*contents are not logged*'
    }
}

Describe 'Repository migration writer checks' -Tag Component {
    BeforeEach {
        $script:previousEnvironment = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REF', 'GITHUB_WORKFLOW_REF', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_TOKEN')) {
            $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REPOSITORY_ID = '5678'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_WORKFLOW_REF = 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-sync.yml@refs/heads/main'
        $env:GITHUB_SHA = 'a' * 40
        $env:GITHUB_RUN_ID = '12345'
        $env:GITHUB_TOKEN = 'synthetic-workflow-read-token'
        $script:runs = @()
        Mock Invoke-RepositorySyncProcess {
            param($Command, $Arguments, $EnvVars)
            $Command | Should -Be 'gh'
            $Arguments | Should -Contain 'GET'
            $Arguments[-1] | Should -Match '^repos/Azure/azure-verified-modules-tools/actions/workflows/repository-management-sync.yml/runs\?'
            $EnvVars.GH_TOKEN | Should -Be 'synthetic-workflow-read-token'
            $selected = if ($Arguments[-1] -match 'page=2$') { @() } else { $script:runs }
            @{ ExitCode = 0; StdOut = (ConvertTo-Json @{ workflow_runs = @($selected) } -Depth 5); StdErr = '' }
        }
    }

    AfterEach {
        foreach ($name in $script:previousEnvironment.Keys) {
            $value = $script:previousEnvironment[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
        }
    }

    It 'ignores the current run and same-revision queued followers' {
        $script:runs = @(
            @{ id = 12345; status = 'in_progress'; head_sha = $env:GITHUB_SHA }
            @{ id = 12346; status = 'queued'; head_sha = $env:GITHUB_SHA }
        )
        { Assert-RepositoryMigrationWriters } | Should -Not -Throw
    }

    It 'rejects a conflicting <Status> run without cancelling it' -ForEach @(
        @{ Status = 'in_progress'; Sha = ('a' * 40) }
        @{ Status = 'queued'; Sha = ('b' * 40) }
        @{ Status = 'waiting'; Sha = ('b' * 40) }
    ) {
        $script:runs = @(@{ id = 98765; status = $Status; head_sha = $Sha })
        { Assert-RepositoryMigrationWriters } | Should -Throw '*98765*Nothing was cancelled*'
    }

    It 'paginates rather than accepting the first hundred results as a full inventory' {
        $script:runs = @(1..100 | ForEach-Object { @{ id = 20000 + $_; status = 'queued'; head_sha = $env:GITHUB_SHA } })
        Assert-RepositoryMigrationWriters
        Should -Invoke Invoke-RepositorySyncProcess -Times 5 -Exactly -ParameterFilter { $Arguments[-1] -match 'page=2$' }
    }

    It 'refuses untrusted <EnvironmentKey> before external calls' -ForEach @(
        @{ EnvironmentKey = 'GITHUB_REF'; Value = 'refs/heads/preparation' }
        @{ EnvironmentKey = 'GITHUB_WORKFLOW_REF'; Value = 'Azure/azure-verified-modules-tools/.github/workflows/another.yml@refs/heads/main' }
    ) {
        [Environment]::SetEnvironmentVariable($EnvironmentKey, $Value, 'Process')
        { Assert-RepositoryMigrationWriters } | Should -Throw '*trusted Tools main*'
        Should -Invoke Invoke-RepositorySyncProcess -Times 0 -Exactly
    }
}

Describe 'Repository migration complete inventory' -Tag Component {
    BeforeEach {
        $script:previousOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'migration-output'
        Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        $script:pair = New-AvmTestMigrationStatePair
        $script:templateState = New-AvmTestHistoricalRepositoryState -Repository 'Azure/terraform-azurerm-avm-template' -RepositoryId 2345
        $script:appState = New-AvmTestHistoricalRepositoryState -Repository 'Azure/avm-gh-app' -RepositoryId 3456
        $script:imagesState = New-AvmTestHistoricalRepositoryState -Repository 'Azure/avm-container-images-cicd-agents-and-runners' -RepositoryId 4567
        $script:aliasPair = New-AvmTestLegacyAliasStatePair
        $script:settings = New-AvmTestBamiSettings
        $script:fixture = @{
            SourcePrefix = "bami-identities/$($script:settings.TEST_BAMI_TENANT_ID)/"
            BackupPrefix = "bami-consolidation/$($script:settings.TEST_BAMI_TENANT_ID)/"
            Sources = @(); Backups = @(); Destinations = @()
            Pair = $script:pair
            States = @{
                'avm-ptn-example-repo.tfstate' = $script:pair.Destination
                'avm-template.tfstate' = $script:templateState
                'avm-gh-app.tfstate' = $script:appState
                'avm-container-images-cicd-agents-and-runners.tfstate' = $script:imagesState
            }
            Repositories = @{
                $script:pair.Repository = $script:pair.GitHubRepository
            }
            Reads = [Collections.Generic.List[string]]::new()
            Paths = [Collections.Generic.List[string]]::new()
            PublicationReads = [Collections.Generic.List[object]]::new()
            Events = [Collections.Generic.List[string]]::new()
        }
        $states = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($entry in $script:fixture.States.GetEnumerator()) { $states.Add($entry.Key, $entry.Value) }
        $states.Add($script:aliasPair.LegacyKey, $script:aliasPair.Legacy)
        $states.Add($script:aliasPair.CanonicalKey, $script:aliasPair.Canonical.Destination)
        $script:fixture.States = $states
        $script:fixture.Repositories[$script:aliasPair.Canonical.Repository] = $script:aliasPair.Canonical.GitHubRepository
        $fixture = $script:fixture
        Mock Assert-RepositoryMigrationWriters { }
        Mock Assert-RepositoryMigrationStorage { }
        Mock Resolve-AvmRepositorySyncFederationContext { @{ RepositoryId = '5678'; OrganizationId = '6844498' } }
        Mock Resolve-AvmTool -ModuleName Avm.Authoring { [pscustomobject]@{ Path = 'synthetic-terraform'; Version = '1.15.8' } }
        Mock Invoke-RepositorySyncProcess { throw 'External execution forbidden in component inventory tests.' }
        Mock Invoke-RepositoryMigrationAzure { throw 'Azure transport forbidden in component inventory tests.' }
        Mock Invoke-RepositoryGitHubApi ({
            param($Endpoint)
            $name = $Endpoint.Substring('repos/'.Length)
            if (-not $fixture.Repositories.ContainsKey($name)) { throw 'Unexpected repository lookup.' }
            $fixture.Repositories[$name]
        }.GetNewClosure())
        Mock Get-RepositoryMigrationScope ({
            param($Backend, $Settings, $RepoId, $Repository)
            @{ RepoId = $RepoId; SubscriptionId = $Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'] }
        }.GetNewClosure())
        Mock Get-RepositoryMigrationBlobList ({
            param($Backend, $Prefix)
            if ($Prefix -ceq $fixture.SourcePrefix) { return $fixture.Sources }
            if ($Prefix -ceq $fixture.BackupPrefix) { return $fixture.Backups }
            if ($Prefix -ceq 'avm-') { return $fixture.Destinations }
            throw 'Inventory escaped the exact configured tenant/container scope.'
        }.GetNewClosure())
        Mock Get-RepositoryMigrationBlob ({
            param($Backend, $Name, $Path)
            if (-not $fixture.States.ContainsKey($Name)) { throw 'Unexpected state key.' }
            $fixture.Reads.Add($Name)
            $fixture.Paths.Add($Path)
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $fixture.States[$Name] -Depth 100))
            return $true
        }.GetNewClosure())
        Mock New-RepositoryMigrationTransfer ({
            param($Scope, $Directory, $Terraform, $TerraformVersion, $OriginalDestinationPath)
            $fixture.Events.Add('prepare')
            @{
                Position = 'Prepared'
                Inventory = @{
                    destination = @{
                        State = $fixture.Pair.Destination
                        Hash = (Get-FileHash -LiteralPath $OriginalDestinationPath).Hash
                    }
                    source = @{ State = $fixture.Pair.Source }
                }
            }
        }.GetNewClosure())
        Mock Invoke-RepositoryMigrationTransfer ({
            param($Transfer, $PlanOnly)
            $fixture.Events.Add($PlanOnly ? 'preview' : 'publish')
            $fixture.PublicationReads.Add($fixture.Reads.ToArray())
            return $PlanOnly ? 'Preview' : 'Complete'
        }.GetNewClosure())
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', ($null -eq $script:previousOutput ? [NullString]::Value : $script:previousOutput), 'Process')
        Should -Invoke Invoke-RepositorySyncProcess -Times 0 -Exactly
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 0 -Exactly
    }

    It 'allows a genuinely new repository fleet with no prior state without inventing one' {
        $result = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly
        $result.Ready | Should -BeTrue
        $result.MigrationRequired | Should -Be 0
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'accounts for a failed-before-sync repository with only its ordinary legacy state' {
        $script:fixture.Destinations = @(@{ name = 'avm-ptn-example-repo.tfstate' })
        $result = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings
        $result.Ready | Should -BeTrue
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'audits the excluded historical <RepoId> state without creating a transfer in <Mode> mode' -ForEach @(
        @{ RepoId = 'avm-template'; Repository = 'Azure/terraform-azurerm-avm-template'; Preview = $true; Mode = 'preview' }
        @{ RepoId = 'avm-template'; Repository = 'Azure/terraform-azurerm-avm-template'; Preview = $false; Mode = 'apply' }
        @{ RepoId = 'avm-gh-app'; Repository = 'Azure/avm-gh-app'; Preview = $true; Mode = 'preview' }
        @{ RepoId = 'avm-gh-app'; Repository = 'Azure/avm-gh-app'; Preview = $false; Mode = 'apply' }
        @{ RepoId = 'avm-container-images-cicd-agents-and-runners'; Repository = 'Azure/avm-container-images-cicd-agents-and-runners'; Preview = $true; Mode = 'preview' }
        @{ RepoId = 'avm-container-images-cicd-agents-and-runners'; Repository = 'Azure/avm-container-images-cicd-agents-and-runners'; Preview = $false; Mode = 'apply' }
    ) {
        $script:fixture.Destinations = @(@{ name = "$RepoId.tfstate" })
        $result = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$Preview
        $result.Ready | Should -BeTrue
        $result.MigrationRequired | Should -Be 0
        $script:fixture.Reads | Should -Be @("$RepoId.tfstate")
        $script:fixture.Events | Should -HaveCount 0
        $state = $script:fixture.States["$RepoId.tfstate"]
        $state.resources | Should -HaveCount 14
        @($state.resources | ForEach-Object { $_.instances }) | Should -HaveCount 56
        @($state.resources | Where-Object mode -CEQ 'managed' | ForEach-Object { $_.instances }) | Should -HaveCount 52
        Should -Invoke Invoke-RepositoryGitHubApi -Times 0 -Exactly -ParameterFilter {
            $Endpoint -ceq "repos/$Repository"
        }
        Should -Invoke Get-RepositoryMigrationScope -Times 0 -Exactly
        Should -Invoke New-RepositoryMigrationTransfer -Times 0 -Exactly
        Should -Invoke Invoke-RepositoryMigrationTransfer -Times 0 -Exactly
    }

    It 'includes all recognized historical states in the full inventory before any <Mode> transfer' -ForEach @(
        @{ Preview = $true; Ready = $false; Event = 'preview'; Mode = 'preview' }
        @{ Preview = $false; Ready = $true; Event = 'publish'; Mode = 'apply' }
    ) {
        $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'avm-ptn-example-repo.tfstate' })
        $script:fixture.Destinations = @(
            @{ name = 'avm-ptn-example-repo.tfstate' }, @{ name = 'avm-template.tfstate' }
            @{ name = 'avm-gh-app.tfstate' }, @{ name = 'avm-container-images-cicd-agents-and-runners.tfstate' }
        )
        $result = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$Preview
        $result.Ready | Should -Be $Ready
        $result.MigrationRequired | Should -Be 1
        $script:fixture.Events | Should -Be @('prepare', $Event)
        $script:fixture.PublicationReads | Should -HaveCount 1
        $script:fixture.PublicationReads[0] | Should -Be @(
            'avm-container-images-cicd-agents-and-runners.tfstate', 'avm-gh-app.tfstate'
            'avm-ptn-example-repo.tfstate', 'avm-template.tfstate'
        )
        Should -Invoke Get-RepositoryMigrationScope -Times 0 -Exactly -ParameterFilter { $RepoId -cne 'avm-ptn-example-repo' }
    }

    It 'includes former state regardless of worker selection and reports ready <Ready> in <Mode> mode' -ForEach @(
        @{ Preview = $null; Ready = $false; Event = 'preview'; Mode = 'default preview' }
        @{ Preview = $true; Ready = $false; Event = 'preview'; Mode = 'explicit preview' }
        @{ Preview = $false; Ready = $true; Event = 'publish'; Mode = 'explicit apply' }
    ) {
        $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'avm-ptn-example-repo.tfstate' })
        $script:fixture.Destinations = @(@{ name = 'avm-ptn-example-repo.tfstate' })
        $parameters = @{ Backend = $script:pair.Backend; BamiSettings = $script:settings }
        if ($null -ne $Preview) { $parameters['PlanOnly'] = $Preview }
        $result = & $script:driver @parameters
        $result.Ready | Should -Be $Ready
        $result.PlanOnly | Should -Be ($null -eq $Preview -or $Preview)
        $script:fixture.Events | Should -Be @('prepare', $Event)
        Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -Be "ready=$($Ready.ToString().ToLowerInvariant())"
    }

    It 'rejects incomplete or ambiguous full inventory before publication: <Case>' -ForEach @(
        @{ Case = 'source without destination' }
        @{ Case = 'orphan completion record' }
        @{ Case = 'foreign tenant' }
        @{ Case = 'aliased source key' }
        @{ Case = 'renamed repository' }
        @{ Case = 'retired address owns BAMI' }
    ) {
        $script:fixture.Destinations = @(@{ name = 'avm-ptn-example-repo.tfstate' })
        switch ($Case) {
            'source without destination' {
                $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'avm-ptn-other.tfstate' })
            }
            'orphan completion record' {
                $script:fixture.Backups = @(@{ name = $script:fixture.BackupPrefix + 'avm-ptn-example-repo/complete.json' })
            }
            'foreign tenant' { $script:fixture.Sources = @(@{ name = 'bami-identities/another-tenant/avm-ptn-example-repo.tfstate' }) }
            'aliased source key' { $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'terraform-azure-avm-ptn-example-repo.tfstate' }) }
            'renamed repository' { $script:pair.Destination.resources[0].instances[0].attributes.full_name += '-renamed' }
            'retired address owns BAMI' { $script:pair.Destination.resources[1].instances[0].attributes.id = $script:pair.Identity.identity_resource_id }
        }
        { & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings } | Should -Throw
        $script:fixture.Events | Should -Not -Contain 'publish'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects unexpected or duplicate keys before state downloads: <Case>' -ForEach @(
        @{ Case = 'unknown ordinary state'; Kind = 'ordinary repository'; Key = 'avm-unrecognized.tfstate'; List = 'Destinations' }
        @{ Case = 'ordinary key case alias'; Kind = 'ordinary repository'; Key = 'avm-ptn-Example-repo.tfstate'; List = 'Destinations' }
        @{ Case = 'ordinary key trailing newline'; Kind = 'ordinary repository'; Key = "avm-ptn-example-repo.tfstate`n::error::injected"; List = 'Destinations' }
        @{ Case = 'ordinary key trailing hyphen'; Kind = 'ordinary repository'; Key = 'avm-ptn-example-repo-.tfstate'; List = 'Destinations' }
        @{ Case = 'ordinary backup suffix'; Kind = 'ordinary repository'; Key = 'avm-ptn-example-repo.tfstate.backup'; List = 'Destinations' }
        @{ Case = 'duplicate ordinary state'; Kind = 'ordinary repository'; Key = 'avm-ptn-example-repo.tfstate'; List = 'Destinations'; Duplicate = $true }
        @{ Case = 'duplicate template state'; Kind = 'ordinary repository'; Key = 'avm-template.tfstate'; List = 'Destinations'; Duplicate = $true }
        @{ Case = 'template source state'; Kind = 'source'; Key = 'avm-template.tfstate'; List = 'Sources' }
        @{ Case = 'historical alias source state'; Kind = 'source'; Key = 'avm-res-redhatopenShift-openshiftcluster.tfstate'; List = 'Sources' }
        @{ Case = 'source key trailing newline'; Kind = 'source'; Key = "avm-ptn-example-repo.tfstate`n"; List = 'Sources' }
        @{ Case = 'duplicate source state'; Kind = 'source'; Key = 'avm-ptn-example-repo.tfstate'; List = 'Sources'; Duplicate = $true }
        @{ Case = 'template recovery'; Kind = 'recovery'; Key = 'avm-template/backup.zip'; List = 'Backups' }
        @{ Case = 'historical alias recovery'; Kind = 'recovery'; Key = 'avm-res-redhatopenShift-openshiftcluster/backup.zip'; List = 'Backups' }
        @{ Case = 'unexpected recovery file'; Kind = 'recovery'; Key = 'avm-ptn-example-repo/other.json'; List = 'Backups' }
        @{ Case = 'duplicate recovery file'; Kind = 'recovery'; Key = 'avm-ptn-example-repo/backup.zip'; List = 'Backups'; Duplicate = $true }
    ) {
        param($Case, $Kind, $Key, $List, [bool] $Duplicate = $false)

        $prefix = switch ($List) {
            'Sources' { $script:fixture.SourcePrefix }
            'Backups' { $script:fixture.BackupPrefix }
            default { '' }
        }
        $keyName = "$prefix$Key"
        $script:fixture[$List] = @(@{ name = $keyName; metadata = @{ private = 'synthetic-private-blob-metadata' } })
        if ($Duplicate) { $script:fixture[$List] += @{ name = $keyName } }
        $failure = $null
        try { & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$false }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Message | Should -Match ([regex]::Escape($Kind))
        $failure.Message | Should -Match ([regex]::Escape((ConvertTo-Json -InputObject $keyName -Compress)))
        $failure.Message | Should -Match 'syntheticstate/repositories'
        $failure.Message | Should -Match 'Expected'
        $failure.Message | Should -Not -Match "synthetic-private-blob-metadata|`n|`r"
        Should -Invoke Get-RepositoryMigrationBlob -Times 0 -Exactly
        Should -Invoke New-RepositoryMigrationTransfer -Times 0 -Exactly
        Should -Invoke Invoke-RepositoryMigrationTransfer -Times 0 -Exactly
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'does not expose a credential embedded in an invalid key diagnostic' {
        $previous = [Environment]::GetEnvironmentVariable('GH_TOKEN')
        try {
            $env:GH_TOKEN = 'synthetic-sensitive-token'
            $script:fixture.Destinations = @(@{ name = 'avm-synthetic-sensitive-token.tfstate' })
            $failure = $null
            try { & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$false }
            catch { $failure = $_.Exception }
            $failure.Message | Should -Match ([regex]::Escape('"avm-***.tfstate"'))
            $failure.Message | Should -Not -Match 'synthetic-sensitive-token'
        }
        finally {
            [Environment]::SetEnvironmentVariable('GH_TOKEN', ($null -eq $previous ? [NullString]::Value : $previous), 'Process')
        }
    }

    It 'audits disjoint historical and current OpenShift owners in <Order> order before <Mode>' -ForEach @(
        @{ First = 'avm-res-redhatopenShift-openshiftcluster.tfstate'; Second = 'avm-res-redhatopenshift-openshiftcluster.tfstate'; Order = 'historical first'; Preview = $true; Mode = 'preview' }
        @{ First = 'avm-res-redhatopenshift-openshiftcluster.tfstate'; Second = 'avm-res-redhatopenShift-openshiftcluster.tfstate'; Order = 'canonical first'; Preview = $true; Mode = 'preview' }
        @{ First = 'avm-res-redhatopenShift-openshiftcluster.tfstate'; Second = 'avm-res-redhatopenshift-openshiftcluster.tfstate'; Order = 'historical first'; Preview = $false; Mode = 'apply' }
        @{ First = 'avm-res-redhatopenshift-openshiftcluster.tfstate'; Second = 'avm-res-redhatopenShift-openshiftcluster.tfstate'; Order = 'canonical first'; Preview = $false; Mode = 'apply' }
    ) {
        $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'avm-ptn-example-repo.tfstate' })
        $script:fixture.Destinations = @(
            @{ name = 'avm-container-images-cicd-agents-and-runners.tfstate' }, @{ name = 'avm-gh-app.tfstate' }
            @{ name = $First }, @{ name = $Second }, @{ name = 'avm-template.tfstate' }
            @{ name = 'avm-ptn-example-repo.tfstate' }
        )
        $before = ConvertTo-Json -InputObject $script:aliasPair.Legacy -Depth 100
        $result = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$Preview
        $result.Ready | Should -Be (-not $Preview)
        $result.MigrationRequired | Should -Be 1
        $script:fixture.PublicationReads | Should -HaveCount 1
        $script:fixture.PublicationReads[0] | Should -Contain $First
        $script:fixture.PublicationReads[0] | Should -Contain $Second
        $script:fixture.PublicationReads[0] | Should -HaveCount 6
        @($script:fixture.Paths | Sort-Object -Unique) | Should -HaveCount 6
        $script:fixture.Events | Should -Be @('prepare', ($Preview ? 'preview' : 'publish'))
        ConvertTo-Json -InputObject $script:aliasPair.Legacy -Depth 100 | Should -BeExactly $before
        @($script:aliasPair.Legacy.resources | Where-Object mode -CEQ 'managed') | Should -HaveCount 8
        @($script:aliasPair.Canonical.Destination.resources | ForEach-Object { $_.instances }) | Should -HaveCount 75
        Should -Invoke Get-RepositoryMigrationScope -Times 1 -Exactly -ParameterFilter { $RepoId -ceq 'avm-ptn-example-repo' }
        Should -Invoke Invoke-RepositoryGitHubApi -Times 1 -Exactly -ParameterFilter {
            $Endpoint -ceq 'repos/Azure/terraform-azurerm-avm-res-redhatopenshift-openshiftcluster'
        }
    }

    It 'blocks unsafe historical alias ownership before publishing a prepared transfer: <Case>' -ForEach @(
        @{ Case = 'missing canonical state'; Message = '*same immutable GitHub repository*' }
        @{ Case = 'different repository ID'; Message = '*same immutable GitHub repository*' }
        @{ Case = 'different repository node'; Message = '*same immutable GitHub repository*' }
        @{ Case = 'different repository name'; Message = '*exact recorded GitHub repository identity*' }
        @{ Case = 'shared lineage'; Message = '*same immutable GitHub repository*' }
        @{ Case = 'missing resource'; Message = '*Incomplete historical ownership*' }
        @{ Case = 'unexpected namespace'; Message = '*recognized flat repository root*' }
        @{ Case = 'aliased resource name'; Message = '*recognized flat repository root*' }
        @{ Case = 'aliased provider'; Message = '*recognized flat repository root*' }
        @{ Case = 'unexpected instance'; Message = '*Unexpected historical instance*' }
        @{ Case = 'string instance index'; Message = '*Unexpected historical instance*' }
        @{ Case = 'missing tenant proof'; Message = '*retired-tenant ownership*' }
        @{ Case = 'BAMI tenant'; Message = '*configured BAMI scope*' }
        @{ Case = 'BAMI identity subscription'; Message = '*configured BAMI scope*' }
        @{ Case = 'BAMI role subscription'; Message = '*BAMI-scoped historical role*' }
        @{ Case = 'foreign federation'; Message = '*historical federation ownership*' }
        @{ Case = 'foreign membership'; Message = '*historical group membership ownership*' }
        @{ Case = 'foreign role principal'; Message = '*historical role ownership*' }
        @{ Case = 'foreign GitHub environment'; Message = '*historical GitHub environment ownership*' }
        @{ Case = 'duplicate GitHub object'; Message = '*duplicate managed ownership*' }
        @{ Case = 'duplicate Azure object'; Message = '*duplicate managed ownership*' }
        @{ Case = 'tainted instance'; Message = '*tainted*' }
        @{ Case = 'deposed instance'; Message = '*Deposed*' }
    ) {
        $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'avm-ptn-example-repo.tfstate' })
        $script:fixture.Destinations = @(
            @{ name = 'avm-ptn-example-repo.tfstate' }, @{ name = $script:aliasPair.LegacyKey }, @{ name = $script:aliasPair.CanonicalKey }
        )
        $legacy = $script:aliasPair.Legacy
        $identity = @($legacy.resources | Where-Object name -CEQ 'identity')[0].instances[0].attributes
        $repository = @($legacy.resources | Where-Object type -CEQ 'github_repository')[0].instances[0].attributes
        switch ($Case) {
            'missing canonical state' { $script:fixture.Destinations = @($script:fixture.Destinations | Where-Object name -CNE $script:aliasPair.CanonicalKey) }
            'different repository ID' { $repository.repo_id = 8888 }
            'different repository node' { $repository.node_id = 'R_synthetic_foreign' }
            'different repository name' { $repository.full_name += '-renamed' }
            'shared lineage' { $legacy.lineage = $script:aliasPair.Canonical.Destination.lineage }
            'missing resource' { $legacy.resources = @($legacy.resources | Where-Object name -CNE 'identity') }
            'unexpected namespace' { $legacy.resources[0].module = 'module.bami[0]' }
            'aliased resource name' { $legacy.resources[0].name = 'CURRENT' }
            'aliased provider' { $legacy.resources[0].provider += '.other' }
            'unexpected instance' { $legacy.resources[0].instances[0].index_key = 0 }
            'string instance index' { @($legacy.resources | Where-Object type -CEQ 'github_repository_environment')[0].instances[0].index_key = '0' }
            'missing tenant proof' { $identity.Remove('output') }
            'BAMI tenant' {
                $legacy.resources[0].instances[0].attributes.tenant_id = $script:settings.TEST_BAMI_TENANT_ID
                $identity.output.value.properties.tenantId = $script:settings.TEST_BAMI_TENANT_ID
            }
            'BAMI identity subscription' { $legacy.resources[0].instances[0].attributes.subscription_id = $script:settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID }
            'BAMI role subscription' {
                @($legacy.resources | Where-Object name -CEQ 'identity_role_assignment')[0].instances[0].attributes.parent_id =
                    "/subscriptions/$($script:settings.TEST_BAMI_SUBSCRIPTION_IDS[0].id)"
            }
            'foreign federation' { @($legacy.resources | Where-Object name -CEQ 'identity_federated_credentials')[0].instances[0].attributes.parent_id += '-foreign' }
            'foreign membership' { @($legacy.resources | Where-Object type -CEQ 'azuread_group_member')[0].instances[0].attributes.member_object_id = '40000000-0000-4000-8000-000000000007' }
            'foreign role principal' { @($legacy.resources | Where-Object name -CEQ 'identity_role_assignment')[0].instances[0].attributes.body.value.properties.principalId = '40000000-0000-4000-8000-000000000007' }
            'foreign GitHub environment' { @($legacy.resources | Where-Object type -CEQ 'github_repository_environment')[0].instances[0].attributes.environment = 'pr-check' }
            'duplicate GitHub object' {
                @($script:aliasPair.Canonical.Destination.resources | Where-Object { $_.type -ceq 'github_repository_environment' -and $_.name -ceq 'no_approval' })[0].instances[0].attributes.id =
                    @($legacy.resources | Where-Object type -CEQ 'github_repository_environment')[0].instances[0].attributes.id
            }
            'duplicate Azure object' { $script:pair.Destination.resources[1].instances[0].attributes.id = $identity.id }
            'tainted instance' { $legacy.resources[0].instances[0].status = 'tainted' }
            'deposed instance' { $legacy.resources[0].instances[0].deposed = 'synthetic' }
        }
        $failure = $null
        try { & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$false }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Message | Should -BeLike $Message
        $failure.Message | Should -Match ([regex]::Escape($script:aliasPair.LegacyKey))
        $failure.Message | Should -Match 'syntheticstate/repositories'
        $failure.Message | Should -Not -Match 'synthetic-private-value-never-logged|synthetic historical opaque private data'
        $script:fixture.Events | Should -Be @('prepare')
        Should -Invoke Invoke-RepositoryMigrationTransfer -Times 0 -Exactly
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'audits historical ownership without requiring the excluded repository to still exist in GitHub' {
        $script:fixture.Destinations = @(@{ name = 'avm-gh-app.tfstate' })
        Mock Invoke-RepositoryGitHubApi { throw 'Synthetic GitHub repository not found.' }
        $result = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$false
        $result.Ready | Should -BeTrue
        $script:fixture.Reads | Should -Be @('avm-gh-app.tfstate')
        $script:fixture.Events | Should -HaveCount 0
        Should -Invoke Invoke-RepositoryGitHubApi -Times 0 -Exactly
        Should -Invoke Invoke-RepositoryMigrationTransfer -Times 0 -Exactly
    }

    It 'rejects unsafe historical template ownership before a prepared transfer is published: <Case>' -ForEach @(
        @{ Case = 'repository alias'; Message = '*exact recorded GitHub repository identity*' }
        @{ Case = 'invalid repository ID'; Message = '*exact recorded GitHub repository identity*' }
        @{ Case = 'missing repository node ID'; Message = '*exact recorded GitHub repository identity*' }
        @{ Case = 'live BAMI module'; Message = '*recognized flat repository root*' }
        @{ Case = 'mixed modern root'; Message = '*recognized flat repository root*' }
        @{ Case = 'BAMI tenant'; Message = '*configured BAMI scope*' }
        @{ Case = 'missing identity proof'; Message = '*retired-tenant ownership*' }
        @{ Case = 'foreign label repository'; Message = '*historical GitHub label ownership*' }
        @{ Case = 'foreign label ID'; Message = '*historical GitHub label ownership*' }
        @{ Case = 'foreign label index'; Message = '*historical GitHub label ownership*' }
        @{ Case = 'duplicate label index'; Message = '*Duplicate instance index*' }
        @{ Case = 'foreign ruleset repository'; Message = '*historical GitHub ruleset ownership*' }
        @{ Case = 'invalid ruleset ID'; Message = '*historical GitHub ruleset ownership*' }
        @{ Case = 'missing ruleset'; Message = '*Incomplete historical ownership*' }
        @{ Case = 'duplicate physical owner'; Message = '*duplicate managed ownership*' }
        @{ Case = 'duplicate GitHub owner'; Message = '*duplicate managed ownership*' }
    ) {
        $script:fixture.Sources = @(@{ name = $script:fixture.SourcePrefix + 'avm-ptn-example-repo.tfstate' })
        $script:fixture.Destinations = @(
            @{ name = 'avm-ptn-example-repo.tfstate' }, @{ name = 'avm-template.tfstate' }
        )
        $state = $script:templateState
        $repository = @($state.resources | Where-Object type -CEQ 'github_repository')[0].instances[0].attributes
        $identity = @($state.resources | Where-Object name -CEQ 'identity')[0].instances[0].attributes
        $labels = @($state.resources | Where-Object type -CEQ 'github_issue_label')[0]
        $ruleset = @($state.resources | Where-Object type -CEQ 'github_repository_ruleset')[0]
        switch ($Case) {
            'repository alias' { $repository.full_name = 'Azure/terraform-azure-avm-template' }
            'invalid repository ID' { $repository.repo_id = 0 }
            'missing repository node ID' { $repository.Remove('node_id') }
            'live BAMI module' { $state.resources[0].module = 'module.bami[0]' }
            'mixed modern root' { $state.resources += $script:pair.Destination.resources[0] }
            'BAMI tenant' {
                $state.resources[0].instances[0].attributes.tenant_id = $script:settings.TEST_BAMI_TENANT_ID
                $identity.output.value.properties.tenantId = $script:settings.TEST_BAMI_TENANT_ID
            }
            'missing identity proof' { $identity.Remove('output') }
            'foreign label repository' { $labels.instances[0].attributes.repository = 'foreign' }
            'foreign label ID' { $labels.instances[0].attributes.id += '-other' }
            'foreign label index' { $labels.instances[0].index_key = 'foreign' }
            'duplicate label index' { $labels.instances[1].index_key = $labels.instances[0].index_key }
            'foreign ruleset repository' { $ruleset.instances[0].attributes.repository = 'foreign' }
            'invalid ruleset ID' { $ruleset.instances[0].attributes.id = 'not-a-ruleset-id' }
            'missing ruleset' { $state.resources = @($state.resources | Where-Object type -CNE 'github_repository_ruleset') }
            'duplicate physical owner' { $script:pair.Destination.resources[1].instances[0].attributes.id = $identity.id }
            'duplicate GitHub owner' {
                $script:pair.Destination.resources += @{
                    module = 'module.github'; mode = 'managed'; type = 'github_repository_ruleset'; name = 'main'
                    provider = 'provider["registry.terraform.io/integrations/github"]'; instances = $ruleset.instances
                }
            }
        }
        { & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -PlanOnly:$false } |
            Should -Throw $Message
        $script:fixture.Events | Should -Be @('prepare')
        Should -Invoke Invoke-RepositoryMigrationTransfer -Times 0 -Exactly
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'does no external discovery or writes for WhatIf' {
        $null = & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings -WhatIf
        Should -Invoke Assert-RepositoryMigrationWriters -Times 0 -Exactly
        Should -Invoke Assert-RepositoryMigrationStorage -Times 0 -Exactly
        Should -Invoke Get-RepositoryMigrationBlobList -Times 0 -Exactly
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'rejects substituting a BAMI <Client> client for the state-only identity' -ForEach @(
        @{ Client = 'CONTROLLER' }, @{ Client = 'BICEP' }
    ) {
        $script:pair.Backend.ClientId = $script:settings["TEST_BAMI_${Client}_CLIENT_ID"]
        { & $script:driver -Backend $script:pair.Backend -BamiSettings $script:settings } | Should -Throw '*separate state-only identity*'
        Should -Invoke Assert-RepositoryMigrationStorage -Times 0 -Exactly
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'wires readiness ahead of workers using only the existing plan-only input and concurrency' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $workflow | Should -Match 'needs: \[generate-matrix, migrate-state\]\s+if: needs.migrate-state.outputs.ready == ''true'''
        $workflow | Should -Match 'ready: \$\{\{ steps.migration.outputs.ready \}\}'
        $workflow | Should -Match 'PLAN_ONLY: \$\{\{ github.event_name == ''workflow_dispatch'' && inputs.plan_only \}\}'
        $workflow | Should -Match 'group: repository-sync\s+cancel-in-progress: false'
        $workflow | Should -Match 'GITHUB_TOKEN: \$\{\{ github.token \}\}'
        $workflow | Should -Not -Match 'AVM_REPOSITORY_SYNC_STATE_LAYOUT|state_layout|unified-v1|migration_approved'
        $workflow | Should -Not -Match 'actions: write|permissions-actions:'
    }
}
