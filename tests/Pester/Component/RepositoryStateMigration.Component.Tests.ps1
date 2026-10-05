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
        $script:settings = New-AvmTestBamiSettings
        $script:fixture = @{
            SourcePrefix = "bami-identities/$($script:settings.TEST_BAMI_TENANT_ID)/"
            BackupPrefix = "bami-consolidation/$($script:settings.TEST_BAMI_TENANT_ID)/"
            Sources = @(); Backups = @(); Destinations = @()
            Pair = $script:pair
            Events = [Collections.Generic.List[string]]::new()
        }
        $fixture = $script:fixture
        Mock Assert-RepositoryMigrationWriters { }
        Mock Assert-RepositoryMigrationStorage { }
        Mock Resolve-AvmRepositorySyncFederationContext { @{ RepositoryId = '5678'; OrganizationId = '6844498' } }
        Mock Resolve-AvmTool -ModuleName Avm.Authoring { [pscustomobject]@{ Path = 'synthetic-terraform'; Version = '1.15.8' } }
        Mock Invoke-RepositorySyncProcess { throw 'External execution forbidden in component inventory tests.' }
        Mock Invoke-RepositoryMigrationAzure { throw 'Azure transport forbidden in component inventory tests.' }
        Mock Invoke-RepositoryGitHubApi ({ $fixture.Pair.GitHubRepository }.GetNewClosure())
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
            if ($Name -cne 'avm-ptn-example-repo.tfstate') { throw 'Unexpected state key.' }
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $fixture.Pair.Destination -Depth 100))
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
