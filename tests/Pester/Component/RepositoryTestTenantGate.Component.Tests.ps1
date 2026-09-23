BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:driver = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $libRoot = Join-Path (Split-Path $script:driver -Parent) 'lib'
    . (Join-Path $libRoot 'RepoTree.ps1')
    . (Join-Path $libRoot 'AvmPreCommit.ps1')
    . (Join-Path $libRoot 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    foreach ($name in @('Logging', 'RepositoryConfig', 'BranchProtection', 'UnmanagedRulesets', 'CodeQlDefaultSetup', 'TeamsAndUsers', 'TerraformOperations')) {
        . (Join-Path $libRoot "$name.ps1")
    }
}

Describe 'Repository sync test tenant selection' -Tag Component {
    BeforeEach {
        $script:previousEnvironment = @{}
        foreach ($environmentName in @('ARM_USE_AZUREAD', 'GITHUB_EVENT_NAME', 'GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REF', 'AVM_BAMI_TEST_TENANT_SYNC_ENABLED')) {
            $script:previousEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:AVM_BAMI_TEST_TENANT_SYNC_ENABLED = 'false'
        $script:terraformRoot = Join-Path $TestDrive ('terraform-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:terraformRoot
        $script:configPath = Join-Path $TestDrive 'repository-config.json'
        $script:config = @{
            repositoryGroups = @(@{ name = 'default'; order = -1; repositories = @('*'); testTenant = 'bami' })
        }
        $script:config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:configPath
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
        }
        Mock Start-Process { throw [System.InvalidOperationException]::new('ordinary-sync-process-boundary') }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring { throw [System.InvalidOperationException]::new('candidate-sync-process-boundary') }
    }

    It 'rejects an incomplete backend before tenant selection or repository work' -ForEach @(
        @{ Missing = 'stateTenantId' }
        @{ Missing = 'stateSubscriptionId' }
        @{ Missing = 'stateClientId' }
        @{ Missing = 'stateStorageAccountName' }
        @{ Missing = 'stateContainerName' }
        @{ Missing = 'all' }
    ) {
        foreach ($name in @($script:arguments.Keys | Where-Object { $_ -like 'state*' })) {
            if ($Missing -eq 'all' -or $name -eq $Missing) { $script:arguments.Remove($name) }
        }
        Mock Resolve-RepositoryTestTenantSettings {}
        Mock Clear-TerraformWorkspace {}

        { & $script:driver @script:arguments } | Should -Throw '*all five*'
        Should -Invoke Resolve-RepositoryTestTenantSettings -Exactly 0
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
    }

    It 'rejects invalid backend storage before repository work' -ForEach @(
        @{ Name = 'stateStorageAccountName'; Value = 'UpperCaseAccount'; Message = '*state storage account*' }
        @{ Name = 'stateContainerName'; Value = 'state/path'; Message = '*state container*' }
    ) {
        $script:arguments[$Name] = $Value
        { & $script:driver @script:arguments } | Should -Throw $Message
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
    }

    AfterEach {
        foreach ($environmentName in $script:previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($environmentName, $script:previousEnvironment[$environmentName])
        }
    }

    It 'routes selected BAMI on <Event> with removed flag <Flag> and plan <PlanOnly>' -TestCases @(
        @{ Event = 'workflow_dispatch'; Flag = 'absent'; PlanOnly = $false }
        @{ Event = 'workflow_dispatch'; Flag = 'false'; PlanOnly = $false }
        @{ Event = 'workflow_dispatch'; Flag = 'absent'; PlanOnly = $true }
        @{ Event = 'workflow_dispatch'; Flag = 'false'; PlanOnly = $true }
        @{ Event = 'schedule'; Flag = 'absent'; PlanOnly = $false }
        @{ Event = 'schedule'; Flag = 'false'; PlanOnly = $false }
        @{ Event = 'repository_dispatch'; Flag = 'absent'; PlanOnly = $false }
        @{ Event = 'repository_dispatch'; Flag = 'false'; PlanOnly = $false }
    ) {
        param($Event, $Flag, $PlanOnly)

        $env:GITHUB_EVENT_NAME = $Event
        if ($Flag -ceq 'absent') { [Environment]::SetEnvironmentVariable('AVM_BAMI_TEST_TENANT_SYNC_ENABLED', $null) }
        $script:arguments.planOnly = $PlanOnly
        Mock Invoke-AvmBamiRepositoryIdentity { @{ Status = 'PendingCandidateIdentity'; ConsumerSettings = $null } }
        Mock Clear-TerraformWorkspace {}

        $result = & $script:driver @script:arguments

        $result.Status | Should -BeExactly 'PendingCandidateIdentity'
        $expectedPlan = $PlanOnly
        Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 1 -ParameterFilter {
            $PlanOnly -eq $expectedPlan -and $RepoId -ceq 'avm-ptn-example-repo' -and
            $Repository -ceq 'Azure/terraform-azurerm-avm-ptn-example-repo' -and
            $BamiValues.Count -eq 8 -and $BamiValues.TEST_BAMI_TENANT_ID -ceq '10000000-0000-4000-8000-000000000001' -and
            $Backend.TenantId -ceq '44444444-4444-4444-8444-444444444444'
        }
        Should -Invoke Clear-TerraformWorkspace -Exactly 1
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
    }

    It 'rejects a missing BAMI value before cleanup or repository work: <Missing>' -ForEach @(
        @{ Missing = 'TEST_BAMI_TENANT_ID' }
        @{ Missing = 'TEST_BAMI_CONTROLLER_CLIENT_ID' }
        @{ Missing = 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID' }
        @{ Missing = 'TEST_BAMI_SUBSCRIPTION_IDS' }
        @{ Missing = 'TEST_BAMI_MANAGEMENT_GROUP_ID' }
        @{ Missing = 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME' }
        @{ Missing = 'TEST_BAMI_BICEP_CLIENT_ID' }
        @{ Missing = 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID' }
        @{ Missing = 'all' }
    ) {
        if ($Missing -ceq 'all') { $script:arguments.Remove('bamiSettings') }
        else { $script:arguments.bamiSettings.Remove($Missing) }
        Mock Clear-TerraformWorkspace {}
        Mock Invoke-AvmBamiRepositoryIdentity {}
        foreach ($plan in @($true, $false)) {
            $script:arguments.planOnly = $plan
            { & $script:driver @script:arguments } | Should -Throw '*BAMI*'
        }
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
        Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 0
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects inconsistent BAMI values before cleanup: <Case>' -ForEach @(
        @{ Case = 'shared execution identity'; Change = { param($v) $v.TEST_BAMI_BICEP_CLIENT_ID = $v.TEST_BAMI_CONTROLLER_CLIENT_ID } }
        @{ Case = 'admin in test pool'; Change = { param($v) $v.TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $v.TEST_BAMI_SUBSCRIPTION_IDS[0].id } }
        @{ Case = 'persistent in test pool'; Change = { param($v) $v.TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = $v.TEST_BAMI_SUBSCRIPTION_IDS[0].id } }
    ) {
        & $Change $script:arguments.bamiSettings
        Mock Clear-TerraformWorkspace {}
        Mock Invoke-AvmBamiRepositoryIdentity {}
        { & $script:driver @script:arguments } | Should -Throw '*BAMI*'
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
        Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 0
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects BAMI Actions execution outside trusted tools main: <Repository> <Ref>' -TestCases @(
        @{ Repository = 'fork/azure-verified-modules-tools'; Ref = 'refs/heads/main' }
        @{ Repository = 'Azure/azure-verified-modules-tools'; Ref = 'refs/heads/feature' }
        @{ Repository = 'Azure/azure-verified-modules-tools'; Ref = 'refs/pull/1/merge' }
        @{ Repository = 'Azure/azure-verified-modules-tools'; Ref = '' }
        @{ Repository = ''; Ref = 'refs/heads/main' }
    ) {
        param($Repository, $Ref)
        $env:GITHUB_REPOSITORY = $Repository
        $env:GITHUB_REF = $Ref
        Mock Clear-TerraformWorkspace {}
        Mock Invoke-AvmBamiRepositoryIdentity {}
        { & $script:driver @script:arguments } | Should -Throw '*requires trusted*main*'
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
        Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 0
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'continues the ordinary path for explicit legacy with PlanOnly <PlanOnly>' -TestCases @(
        @{ PlanOnly = $false }
        @{ PlanOnly = $true }
    ) {
        param($PlanOnly)

        $script:config.repositoryGroups[0].testTenant = 'legacy'
        $script:config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:configPath
        $script:arguments.planOnly = $PlanOnly
        $script:arguments.bamiSettings = @{ invalid = 'ignored' }
        $env:GITHUB_REPOSITORY = 'fork/azure-verified-modules-tools'
        $env:GITHUB_REF = 'refs/heads/feature'

        { & $script:driver @script:arguments } | Should -Throw '*ordinary-sync-process-boundary*'
        Should -Invoke Start-Process -Exactly 1 -ParameterFilter { $FilePath -eq 'gh' }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'does not gate repository creation, which does not publish test secrets' {
        $script:arguments.repositoryCreationModeEnabled = $true
        foreach ($name in @($script:arguments.Keys | Where-Object { $_ -like 'state*' })) {
            $script:arguments.Remove($name)
        }
        { & $script:driver @script:arguments } | Should -Throw '*ordinary-sync-process-boundary*'
        Should -Invoke Start-Process -Exactly 1 -ParameterFilter { $FilePath -eq 'terraform' }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects removed metadata option <Option> before any work' -TestCases @(
        @{ Option = 'metadataBackfill' }
        @{ Option = 'metadataUpdateSource' }
    ) {
        param($Option)
        $removedOption = @{ $Option = $true }
        { & $script:driver @script:arguments @removedOption } | Should -Throw "*$Option*"
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
    }

    It 'no longer accepts the removed activation parameter' {
        { & $script:driver @script:arguments -bamiTestTenantSyncEnabled $false } | Should -Throw '*bamiTestTenantSyncEnabled*'
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    Context 'Full management and file preparation' {
        BeforeEach {
            $script:managementState = @{ Events = [System.Collections.Generic.List[string]]::new(); Failure = '' }
            $management = $script:managementState
            Mock Resolve-RepositorySyncStateConfiguration ({ $management.Events.Add('state') }.GetNewClosure())
            Mock Clear-TerraformWorkspace ({ $management.Events.Add('cleanup') }.GetNewClosure())
            Mock Invoke-AvmBamiRepositoryIdentity ({
                $management.Events.Add('identity')
                @{ Status = 'Ready'; ConsumerSettings = @{ fixture = 'identity' } }
            }.GetNewClosure())
            Mock Get-RepositoryDefaultBranchTree ({
                $management.Events.Add('tree')
                @{ Success = $true; DefaultBranch = 'main' }
            }.GetNewClosure())
            Mock Remove-LegacyBranchProtection ({ param($issueLog) $management.Events.Add('protection'); @{ IssueLog = @($issueLog) } }.GetNewClosure())
            Mock Remove-UnmanagedRulesets ({ param($issueLog) $management.Events.Add('rulesets'); @{ IssueLog = @($issueLog) } }.GetNewClosure())
            Mock Disable-CodeQlDefaultSetup ({ param($issueLog) $management.Events.Add('codeql'); @{ IssueLog = @($issueLog) } }.GetNewClosure())
            Mock Resolve-GitHubTeams ({ param($issueLog) $management.Events.Add('teams'); @{ GithubTeams = @{}; IssueLog = @($issueLog) } }.GetNewClosure())
            Mock Remove-DirectCollaborators ({ param($issueLog) $management.Events.Add('collaborators'); return ,$issueLog }.GetNewClosure())
            Mock Remove-UnmanagedRepositoryTeams ({ param($issueLog) $management.Events.Add('unmanaged-teams'); return ,$issueLog }.GetNewClosure())
            Mock Invoke-TerraformInit ({ param($issueLog) $management.Events.Add('init'); return ,$issueLog }.GetNewClosure())
            Mock Invoke-TerraformPlanAndApply ({
                param($issueLog)
                $management.Events.Add('terraform')
                if ($management.Failure -ceq 'terraform') { return ,@(@{ message = 'terraform failed' }) }
                return ,$issueLog
            }.GetNewClosure())
            Mock Invoke-AvmPreCommitForRepository ({
                param($issueLog)
                $management.Events.Add('files')
                if ($management.Failure -ceq 'pre-commit') { throw 'authoring pre-commit failed' }
                @{ HasChanges = $true; IssueLog = @($issueLog) }
            }.GetNewClosure())
        }

        It 'runs the standard management sequence for <Tenant> with plan=<Plan>' -TestCases @(
            @{ Tenant = 'legacy'; Plan = $false }
            @{ Tenant = 'legacy'; Plan = $true }
            @{ Tenant = 'bami'; Plan = $false }
            @{ Tenant = 'bami'; Plan = $true }
        ) {
            param($Tenant, $Plan)
            $script:config.repositoryGroups[0].testTenant = $Tenant
            $script:config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:configPath
            $script:arguments.planOnly = $Plan
            $null = & $script:driver @script:arguments

            $expected = @('state', 'cleanup')
            if ($Tenant -ceq 'bami') { $expected += 'identity' }
            $expected += @('tree', 'protection', 'rulesets', 'codeql', 'teams', 'collaborators', 'unmanaged-teams', 'init', 'terraform', 'files')
            $script:managementState.Events | Should -Be $expected
            Should -Invoke Invoke-TerraformInit -Exactly 1 -ParameterFilter {
                $stateTenantId -eq '44444444-4444-4444-8444-444444444444' -and
                $stateSubscriptionId -eq '55555555-5555-4555-8555-555555555555' -and
                $stateClientId -eq '66666666-6666-4666-8666-666666666666' -and
                $stateStorageAccountName -eq 'tmestorage' -and $stateContainerName -eq 'tme-state'
            }
            Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1 -ParameterFilter {
                $planOnly -eq $Plan -and $stateSubscriptionId -eq '55555555-5555-4555-8555-555555555555'
            }
            Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 1 -ParameterFilter {
                $planOnly -eq $Plan -and $defaultBranch -ceq 'main'
            }
            if ($Tenant -ceq 'bami') {
                Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 1 -ParameterFilter {
                    $PlanOnly -eq $Plan -and $BamiValues.Count -eq 8
                }
            }
            else {
                Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 0
            }
            Should -Invoke Start-Process -Exactly 0
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'retains the pending BAMI identity stop before repository changes' {
            Mock Invoke-AvmBamiRepositoryIdentity { @{ Status = 'PendingIdentityValidation' } }
            $result = & $script:driver @script:arguments
            $result.Status | Should -BeExactly 'PendingIdentityValidation'
            Should -Invoke Get-RepositoryDefaultBranchTree -Exactly 0
            Should -Invoke Invoke-TerraformPlanAndApply -Exactly 0
            Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 0
            Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
        }

        It 'does not prepare or publish files after a normal Terraform failure' {
            $script:managementState.Failure = 'terraform'
            $null = & $script:driver @script:arguments
            Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1
            Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 0
            Get-Content (Join-Path $TestDrive 'issue.log.json') -Raw | Should -Match 'terraform failed'
        }

        It 'surfaces pre-commit failure after earlier normal management without claiming rollback' {
            $script:managementState.Failure = 'pre-commit'
            { & $script:driver @script:arguments } | Should -Throw '*authoring pre-commit failed*'
            $script:managementState.Events[-3..-1] | Should -Be @('init', 'terraform', 'files')
            Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1
            Should -Invoke Remove-LegacyBranchProtection -Exactly 1
            Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeTrue
        }
    }
}
