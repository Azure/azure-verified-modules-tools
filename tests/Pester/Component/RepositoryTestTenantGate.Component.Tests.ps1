BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:driver = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $libRoot = Join-Path (Split-Path $script:driver -Parent) 'lib'
    . (Join-Path $libRoot 'RepoTree.ps1')
    . (Join-Path $libRoot 'AvmPreCommit.ps1')
    . (Join-Path $libRoot 'TestTenant.ps1')
    foreach ($name in @('Logging', 'RepositoryConfig', 'BranchProtection', 'UnmanagedRulesets', 'CodeQlDefaultSetup', 'TeamsAndUsers', 'TerraformOperations')) {
        . (Join-Path $libRoot "$name.ps1")
    }
}

Describe 'Repository sync activation gate' -Tag Component {
    BeforeEach {
        $script:previousAzureAdFlag = $env:ARM_USE_AZUREAD
        $script:previousGitHubEvent = $env:GITHUB_EVENT_NAME
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
        [Environment]::SetEnvironmentVariable('GITHUB_EVENT_NAME', $script:previousGitHubEvent)
        if ($null -eq $script:previousAzureAdFlag) {
            Remove-Item Env:\ARM_USE_AZUREAD -ErrorAction SilentlyContinue
        }
        else {
            $env:ARM_USE_AZUREAD = $script:previousAzureAdFlag
        }
    }

    It 'preserves <InitialTenant> with gate <Gate> and PlanOnly <PlanOnly>' -TestCases @(
        @{ InitialTenant = 'legacy'; Gate = 'absent'; PlanOnly = $false }
        @{ InitialTenant = 'legacy'; Gate = 'false'; PlanOnly = $false }
        @{ InitialTenant = 'legacy'; Gate = 'absent'; PlanOnly = $true }
        @{ InitialTenant = 'legacy'; Gate = 'false'; PlanOnly = $true }
        @{ InitialTenant = 'bami'; Gate = 'absent'; PlanOnly = $false }
        @{ InitialTenant = 'bami'; Gate = 'false'; PlanOnly = $false }
        @{ InitialTenant = 'bami'; Gate = 'absent'; PlanOnly = $true }
        @{ InitialTenant = 'bami'; Gate = 'false'; PlanOnly = $true }
    ) {
        param($InitialTenant, $Gate, $PlanOnly)

        $priorSettings = @{
            ARM_TENANT_ID = "$InitialTenant-tenant"
            ARM_CLIENT_ID = "$InitialTenant-repository-client"
            TEST_SUBSCRIPTION_IDS = "$InitialTenant-subscriptions"
        }
        $variablesPath = Join-Path $script:terraformRoot 'terraform.tfvars.json'
        $priorSettings | ConvertTo-Json | Set-Content -LiteralPath $variablesPath
        $before = (Get-FileHash -LiteralPath $variablesPath -Algorithm SHA256).Hash
        $script:arguments.planOnly = $PlanOnly
        if ($Gate -eq 'false') { $script:arguments.bamiTestTenantSyncEnabled = $false }

        $result = & $script:driver @script:arguments

        $result.Status | Should -BeExactly 'PendingTestTenantActivation'
        $result.TestTenant | Should -BeExactly 'bami'
        (Get-FileHash -LiteralPath $variablesPath -Algorithm SHA256).Hash | Should -BeExactly $before
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
        $script:arguments.bamiTestTenantSyncEnabled = $false

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

    It 'keeps metadata backfill behind the disabled BAMI gate with plan <RequestedPlanOnly>' -TestCases @(
        @{ RequestedPlanOnly = $true }
        @{ RequestedPlanOnly = $false }
    ) {
        param($RequestedPlanOnly)

        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:arguments.metadataBackfill = $true
        $script:arguments.planOnly = $RequestedPlanOnly
        $script:arguments.bamiTestTenantSyncEnabled = $false
        Mock Invoke-AvmPreCommitForRepository {}
        Mock Invoke-AvmBamiRepositoryIdentity {}
        Mock Clear-TerraformWorkspace {}

        $result = & $script:driver @script:arguments

        $result.Status | Should -BeExactly 'PendingTestTenantActivation'
        $result.TestTenant | Should -BeExactly 'bami'
        $env:ARM_USE_AZUREAD | Should -BeExactly 'true'
        Should -Invoke Invoke-AvmPreCommitForRepository -Exactly 0
        Should -Invoke Invoke-AvmBamiRepositoryIdentity -Exactly 0
        Should -Invoke Clear-TerraformWorkspace -Exactly 0
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects the removed Terraform source-reader option before any work' {
        { & $script:driver @script:arguments -metadataUpdateSource } | Should -Throw '*metadataUpdateSource*'
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeFalse
    }

    Context 'Full management with optional metadata creation' {
        BeforeEach {
            $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
            $script:arguments.metadataBackfill = $true
            $script:arguments.bamiTestTenantSyncEnabled = $true
            $script:managementState = @{ Events = [System.Collections.Generic.List[string]]::new(); Failure = '' }
            $management = $script:managementState
            Mock Resolve-RepositorySyncStateConfiguration ({ $management.Events.Add('state') }.GetNewClosure())
            Mock Resolve-RepositoryTestTenantSettings ({
                param($TestTenant)
                $management.Events.Add('tenant')
                @{ TestTenant = $TestTenant; Status = 'Ready'; Settings = @{ fixture = 'bami' } }
            }.GetNewClosure())
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
                if ($management.Failure -ceq 'metadata') { throw 'metadata preparation failed' }
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

            $expected = @('state', 'tenant', 'cleanup')
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
                $metadataBackfill -and $planOnly -eq $Plan -and $defaultBranch -ceq 'main'
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

        It 'surfaces metadata failure after earlier normal management without claiming rollback' {
            $script:managementState.Failure = 'metadata'
            { & $script:driver @script:arguments } | Should -Throw '*metadata preparation failed*'
            $script:managementState.Events[-3..-1] | Should -Be @('init', 'terraform', 'files')
            Should -Invoke Invoke-TerraformPlanAndApply -Exactly 1
            Should -Invoke Remove-LegacyBranchProtection -Exactly 1
            Test-Path (Join-Path $script:terraformRoot 'terraform.tfvars.json') | Should -BeTrue
        }
    }
}
