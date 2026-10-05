BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:driver = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1'
    $lib = Join-Path (Split-Path $script:driver -Parent) 'lib'
    foreach ($name in @('Logging', 'RetryHelpers', 'RepositoryConfig', 'RepoTree', 'AvmPreCommit', 'BranchProtection', 'UnmanagedRulesets', 'CodeQlDefaultSetup', 'TeamsAndUsers', 'TestTenant')) {
        . (Join-Path $lib "$name.ps1")
    }
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
}

Describe 'Repository sync unified driver' -Tag Component {
    BeforeEach {
        $script:previousEnvironment = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REF', 'GITHUB_EVENT_NAME', 'AVM_REPOSITORY_SYNC_STATE_LAYOUT')) {
            $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        [Environment]::SetEnvironmentVariable('AVM_REPOSITORY_SYNC_STATE_LAYOUT', [NullString]::Value, 'Process')
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REPOSITORY_ID = '1239632211'
        $env:GITHUB_REF = 'refs/heads/main'
        $script:terraformRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:terraformRoot -Force
        $script:configPath = Join-Path $TestDrive 'repository-config.json'
        $script:config = @{
            repositoryGroups = @(@{
                name = 'default'; order = -1; repositories = @('*'); testTenant = 'bami'
                entraGroups = @('avm-test-entra-readers', 'avm-test-identity-owners')
            })
        }
        $script:config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:configPath
        $script:arguments = @{
            repoId = 'avm-ptn-example-repo'
            repoUrl = 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo'
            repoConfigFilePath = $script:configPath
            terraformModulePath = $script:terraformRoot
            outputDirectory = $TestDrive
            stateTenantId = '44444444-4444-4444-8444-444444444444'
            stateSubscriptionId = '55555555-5555-4555-8555-555555555555'
            stateClientId = '66666666-6666-4666-8666-666666666666'
            stateStorageAccountName = 'tmestorage'
            stateContainerName = 'tme-state'
            bamiSettings = New-AvmTestBamiSettings
            repositorySyncRepositoryId = '1239632211'
        }
        $script:fixture = @{
            Events = [System.Collections.Generic.List[string]]::new()
            FailAt = ''
            Tools = [pscustomobject]@{
                full_name = 'Azure/azure-verified-modules-tools'; id = 1239632211; fork = $false
                owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
            }
            Repository = [pscustomobject]@{
                full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'; id = 1234; fork = $false
                owner = [pscustomobject]@{ login = 'Azure'; id = 6844498 }
            }
        }
        $fixture = $script:fixture
        Mock Invoke-RepositoryGitHubApi ({
            param($Endpoint)
            $fixture.Events.Add("api:$Endpoint")
            if ($Endpoint -ceq 'repos/Azure/azure-verified-modules-tools') { return $fixture.Tools }
            if ($Endpoint -ceq 'repos/Azure/terraform-azurerm-avm-ptn-example-repo') { return $fixture.Repository }
            throw 'Unexpected API endpoint in isolated driver test.'
        }.GetNewClosure())
        Mock Invoke-RepositorySyncProcess { throw 'External process forbidden in isolated driver test.' }
        Mock Start-Process { throw 'Legacy process forbidden in isolated driver test.' }
        Mock Clear-TerraformWorkspace ({ $fixture.Events.Add('cleanup') }.GetNewClosure())
        Mock Get-RepositoryDefaultBranchTree ({
            $fixture.Events.Add('tree')
            @{ Success = $true; DefaultBranch = 'main' }
        }.GetNewClosure())
        Mock Resolve-GitHubTeams ({
            param($issueLog)
            $fixture.Events.Add('teams')
            @{ GithubTeams = @{}; IssueLog = @($issueLog) }
        }.GetNewClosure())
        Mock Invoke-TerraformInit ({ param($issueLog) $fixture.Events.Add('init'); $issueLog }.GetNewClosure())
        Mock Invoke-TerraformPlanAndApply ({
            param($issueLog)
            $fixture.Events.Add('terraform')
            if ($fixture.FailAt -ceq 'terraform') { throw 'verified Terraform operation failed' }
            $issueLog
        }.GetNewClosure())
        Mock Remove-LegacyBranchProtection ({
            param($issueLog)
            $fixture.Events.Add('protection')
            @{ IssueLog = @($issueLog) }
        }.GetNewClosure())
        Mock Remove-UnmanagedRulesets ({ param($issueLog) $fixture.Events.Add('rulesets'); @{ IssueLog = @($issueLog) } }.GetNewClosure())
        Mock Disable-CodeQlDefaultSetup ({ param($issueLog) $fixture.Events.Add('codeql'); @{ IssueLog = @($issueLog) } }.GetNewClosure())
        Mock Remove-DirectCollaborators ({ param($issueLog) $fixture.Events.Add('collaborators'); $issueLog }.GetNewClosure())
        Mock Remove-UnmanagedRepositoryTeams ({ param($issueLog) $fixture.Events.Add('unmanaged-teams'); $issueLog }.GetNewClosure())
        Mock Invoke-AvmPreCommitForRepository ({
            param($issueLog)
            $fixture.Events.Add('files')
            if ($fixture.FailAt -ceq 'files') { throw 'authoring pre-commit failed' }
            @{ HasChanges = $false; IssueLog = @($issueLog) }
        }.GetNewClosure())
    }

    AfterEach {
        foreach ($name in $script:previousEnvironment.Keys) {
            $value = $script:previousEnvironment[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
        Should -Invoke Start-Process -Exactly 0
    }

    It 'uses one root without a cutover setting with plan-only <PlanOnly> on <Event>' -ForEach @(
        @{ PlanOnly = $false; Event = 'workflow_dispatch' }
        @{ PlanOnly = $true; Event = 'workflow_dispatch' }
        @{ PlanOnly = $false; Event = 'schedule' }
        @{ PlanOnly = $false; Event = 'repository_dispatch' }
    ) {
        $script:arguments.planOnly = $PlanOnly
        $env:GITHUB_EVENT_NAME = $Event
        $null = & $script:driver @script:arguments
        $script:fixture.Events | Should -Be @(
            'api:repos/Azure/azure-verified-modules-tools',
            'api:repos/Azure/terraform-azurerm-avm-ptn-example-repo',
            'tree', 'teams', 'cleanup', 'init', 'terraform',
            'protection', 'rulesets', 'codeql', 'collaborators', 'unmanaged-teams', 'files'
        )
        $variables = Get-Content -Raw -LiteralPath (Join-Path $script:terraformRoot 'terraform.tfvars.json') | ConvertFrom-Json -AsHashtable
        $variables.bami_test_settings.ContainsKey('client_id') | Should -BeFalse
        $variables.bami_test_settings.Count | Should -Be 8
        $variables.repository_sync_repository_id | Should -Be '1239632211'
        $variables.ContainsKey('state_layout') | Should -BeFalse
        $variables.entra_group_names | Should -Be @('avm-test-entra-readers', 'avm-test-identity-owners')
        $expected = $PlanOnly
        Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1 -ParameterFilter { $planOnly -eq $expected }
        Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 1 -ParameterFilter { $planOnly -eq $expected }
        Should -Invoke Invoke-TerraformInit -Exactly 1 -ParameterFilter {
            $stateTenantId -ceq '44444444-4444-4444-8444-444444444444' -and
            $environment.ARM_TENANT_ID -ceq '10000000-0000-4000-8000-000000000001'
        }
    }

    It 'ignores a retired cutover environment value: <Value>' -ForEach @(
        @{ Value = 'split' }
        @{ Value = 'unified-v1' }
    ) {
        $env:AVM_REPOSITORY_SYNC_STATE_LAYOUT = $Value
        $null = & $script:driver @script:arguments
        Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1
        $script:fixture.Events[-1] | Should -Be 'files'
        $variables = Get-Content -Raw -LiteralPath (Join-Path $script:terraformRoot 'terraform.tfvars.json') | ConvertFrom-Json -AsHashtable
        $variables.ContainsKey('state_layout') | Should -BeFalse
    }

    It 'previews without external calls or file writes' {
        $result = & $script:driver @script:arguments -WhatIf
        $result.Status | Should -Be 'Preview'
        $script:fixture.Events | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
    }

    It 'rejects incomplete backend settings before any work: <Missing>' -ForEach @(
        @{ Missing = 'stateTenantId' }
        @{ Missing = 'stateSubscriptionId' }
        @{ Missing = 'stateClientId' }
        @{ Missing = 'stateStorageAccountName' }
        @{ Missing = 'stateContainerName' }
    ) {
        $script:arguments.Remove($Missing)
        { & $script:driver @script:arguments } | Should -Throw '*all five*'
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'rejects each missing producer field before external work: <Missing>' -ForEach @(
        @{ Missing = 'TEST_BAMI_TENANT_ID' }
        @{ Missing = 'TEST_BAMI_CONTROLLER_CLIENT_ID' }
        @{ Missing = 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID' }
        @{ Missing = 'TEST_BAMI_SUBSCRIPTION_IDS' }
        @{ Missing = 'TEST_BAMI_MANAGEMENT_GROUP_ID' }
        @{ Missing = 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME' }
        @{ Missing = 'TEST_BAMI_BICEP_CLIENT_ID' }
        @{ Missing = 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID' }
    ) {
        $script:arguments.bamiSettings.Remove($Missing)
        { & $script:driver @script:arguments } | Should -Throw '*BAMI*'
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'rejects untrusted Actions scope: <Repository> <Ref>' -ForEach @(
        @{ Repository = 'fork/azure-verified-modules-tools'; Ref = 'refs/heads/main' }
        @{ Repository = 'Azure/azure-verified-modules-tools'; Ref = 'refs/heads/feature' }
        @{ Repository = 'Azure/azure-verified-modules-tools'; Ref = 'refs/pull/1/merge' }
        @{ Repository = 'Azure/azure-verified-modules-tools'; Ref = '' }
    ) {
        $env:GITHUB_REPOSITORY = $Repository
        $env:GITHUB_REF = $Ref
        { & $script:driver @script:arguments } | Should -Throw '*trusted*main*'
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'rejects a tools ID not verified by GitHub' {
        $script:fixture.Tools.id = 1234
        { & $script:driver @script:arguments } | Should -Throw '*GitHub did not confirm*'
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
    }

    It 'rejects a different target repository or owner: <Case>' -ForEach @(
        @{ Case = 'fork'; Change = { param($r) $r.fork = $true } }
        @{ Case = 'owner'; Change = { param($r) $r.owner.id = 1 } }
        @{ Case = 'name'; Change = { param($r) $r.full_name = 'Azure/unexpected' } }
        @{ Case = 'id'; Change = { param($r) $r.id = 0 } }
    ) {
        & $Change $script:fixture.Repository
        { & $script:driver @script:arguments } | Should -Throw '*unexpected repository identity*'
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
    }

    It 'rejects retired tenant execution without a cleanup or external call' {
        $script:config.repositoryGroups[0].testTenant = 'legacy'
        $script:config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:configPath
        { & $script:driver @script:arguments } | Should -Throw '*legacy test tenant is retired*'
        $script:fixture.Events | Should -HaveCount 0
    }

    It 'keeps repository creation independent of BAMI and the shared backend' {
        $script:arguments.repositoryCreationModeEnabled = $true
        $script:arguments.bamiSettings = @{}
        foreach ($name in @($script:arguments.Keys | Where-Object { $_ -like 'state*' })) {
            $script:arguments.Remove($name)
        }
        $null = & $script:driver @script:arguments
        $script:fixture.Events | Should -Be @('teams', 'cleanup', 'init', 'terraform')
        Should -Invoke Invoke-TerraformInit -Exactly 1 -ParameterFilter { $repositoryCreationModeEnabled }
        Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 0
    }

    It 'accumulates and deduplicates additional Entra names before the one root' {
        $script:config.repositoryGroups += @{
            name = 'analytics'; order = 10; repositories = @('avm-ptn-example-repo')
            entraGroups = @('avm-test-identity-owners', 'avm-test-fabric-admins')
        }
        $script:config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:configPath
        $null = & $script:driver @script:arguments
        Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1 -ParameterFilter {
            ($entraGroupNames -join ',') -ceq 'avm-test-entra-readers,avm-test-identity-owners,avm-test-fabric-admins'
        }
    }

    It 'does not mutate GitHub policies or files after rejected Terraform' {
        $script:fixture.FailAt = 'terraform'
        { & $script:driver @script:arguments } | Should -Throw '*verified Terraform operation failed*'
        Should -Invoke Remove-LegacyBranchProtection -Exactly 0
        Should -Invoke Remove-DirectCollaborators -Exactly 0
        Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 0
    }

    It 'surfaces file failure without retrying Terraform or claiming rollback' {
        $script:fixture.FailAt = 'files'
        { & $script:driver @script:arguments } | Should -Throw '*authoring pre-commit failed*'
        Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1
        $script:fixture.Events[-1] | Should -Be 'files'
    }

    It 'does not accept retired metadata or activation options: <Option>' -ForEach @(
        @{ Option = 'metadataBackfill' }
        @{ Option = 'metadataUpdateSource' }
        @{ Option = 'bamiTestTenantSyncEnabled' }
        @{ Option = 'stateLayout' }
    ) {
        $removedOption = @{ $Option = $true }
        { & $script:driver @script:arguments @removedOption } | Should -Throw "*$Option*"
        $script:fixture.Events | Should -HaveCount 0
    }
}
