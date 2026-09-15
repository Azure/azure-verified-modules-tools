#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'ManagedFilesUpgrade.ps1')
}

Describe 'Component: Terraform metadata input collection' -Tag Component {
    BeforeEach {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ sha = 'a' * 40 } }
        Mock Get-RepositoryFileAtCommit {
            [pscustomobject]@{
                Content = "ModuleName,ModuleDisplayName,Description,RepoURL`navm-res-storage-account,Storage Account,Creates storage.,https://github.com/Azure/terraform-azurerm-avm-res-storage-account`n"
            }
        }
    }

    It 'gets current CSV metadata at an immutable commit without a registration file' {
        $context = Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName 'Azure/terraform-azurerm-avm-res-storage-account'
        $context.SourceSha | Should -Be ('a' * 40)
        $context.LegacyRecord.Count | Should -Be 1
        $context.LegacyRecord[0].Description | Should -Be 'Creates storage.'
        $context.ContainsKey('SeedPath') | Should -BeFalse
        Should -Invoke Get-RepositoryFileAtCommit -Exactly 1 -ParameterFilter {
            $Repository -ceq 'Azure/Azure-Verified-Modules' -and
            $Path -ceq 'docs/static/module-indexes/TerraformResourceModules.csv' -and $Sha -ceq ('a' * 40)
        }
    }

    It 'refuses an invalid index commit rather than using an unpinned response' {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ sha = 'main' } }
        { Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName 'Azure/terraform-azurerm-avm-res-storage-account' } |
            Should -Throw '*commit is missing or invalid*'
        Should -Invoke Get-RepositoryFileAtCommit -Times 0
    }
}

Describe 'Component: Terraform metadata workflow scope' -Tag Component {
    It 'enables backfill only for an explicit workflow_dispatch input and keeps CI credential checks' {
        $workflow = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $expression = "METADATA_BACKFILL_ENABLED: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.metadata_backfill \|\| false \}\}"
        [regex]::Matches($workflow, $expression).Count | Should -Be 2
        $workflow | Should -Match '(?s)metadata_backfill:.*?default: false\s+type: boolean'
        $workflow | Should -Not -Match 'AVM_SYNC_PAUSED'
        $ci = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $ci | Should -Match "if:.*vars\.ARM_CLIENT_ID != ''"
    }

    It 'loads branch code for metadata creation and skips Azure state, settings, and project changes' {
        $workflow = Get-Content (Join-Path $repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $driver = Get-Content (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1') -Raw
        $workflow | Should -Match "(?s)METADATA_BACKFILL_ENABLED -eq 'true'.*?Import-Module \(Join-Path .*?'src' 'Avm.Authoring' 'Avm.Authoring.psd1'\)"
        foreach ($step in @('Setup Terraform', 'Resolve state backend', 'Azure Login for state \(OIDC\)', 'Download Labels CSV File')) {
            $workflow | Should -Match ("(?s)- name: " + $step + "\s+if:.*?!inputs.metadata_backfill")
        }
        $workflow | Should -Match 'inputs.sync_project_items && !inputs.metadata_backfill'
        $driver.IndexOf('return Invoke-AvmPreCommitForRepository') |
            Should -BeLessThan $driver.IndexOf('$env:ARM_USE_AZUREAD = "true"')
        $workflow | Should -Not -Match 'reviewed-seeds|SeedManifestPath'
    }
}

Describe 'Component: metadata backfill repository sync' -Tag Component {
    BeforeEach {
        $script:originalEvent = $env:GITHUB_EVENT_NAME
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:existingReview = $false
        $script:existingBranch = $false
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        Mock Import-Module {}
        Mock Get-AvmRepositoryMetadataBackfillContext { @{ LegacyRecord = @(@{ ModuleDisplayName = 'Example' }); SourceSha = 'a' * 40 } }
        Mock Invoke-RepositoryGitHub {
            if ($script:existingReview) { [pscustomobject]@{ number = 42; url = 'https://github.com/Azure/example/pull/42' } }
        }
        Mock Get-RepositoryBranchHead { if ($script:existingBranch) { 'b' * 40 } }
        Mock Invoke-AvmMetadataBackfillPreparation {
            $script:events.Add('metadata')
            [System.IO.File]::WriteAllText((Join-Path $Context.Root 'metadata.json'), '{}')
            [pscustomobject]@{ Status = 'pass'; Modules = @(); UpdateSource = $Context.State.UpdateSource }
        }
        Mock Invoke-RepositoryFileSync {
            param($Repository, $PlanOnly, $Prepare, $State, $ReviewOnly)
            $script:events.Add('clone')
            & $Prepare @{ Root = $script:root; Repository = @{ full_name = $Repository }; State = $State; PlanOnly = [bool]$PlanOnly }
            @{
                HasChanges = $true
                Status = if ($PlanOnly) { 'Planned' } elseif ($ReviewOnly) { 'ReviewRequired' } else { 'Merged' }
                PullRequestUrl = if ($PlanOnly) { $null } else { 'https://github.com/Azure/example/pull/43' }
            }
        }
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Set-TerraformCodeowners {}
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $false; Reason = 'unchanged' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            $script:events.Add('pre-commit')
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
        $script:parameters = @{
            orgAndRepoName = 'Azure/terraform-azurerm-avm-res-example-resource'
            repoId = 'avm-res-example-resource'
            repositoryConfigDir = $TestDrive
            codeOwnersDefaultTeams = @()
            codeOwnersFileProtectionTeams = @('azure-verified-modules-engineering-owners')
            defaultBranch = 'main'
            planOnly = $false
            issueLog = @()
        }
    }

    AfterEach { $env:GITHUB_EVENT_NAME = $script:originalEvent }

    It 'preserves the normal Terraform sync behavior when metadata creation is not selected' {
        $result = Invoke-AvmPreCommitForRepository @script:parameters -forceFileUpdate $true
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $script:events | Should -Be @('clone', 'pre-commit')
        Should -Invoke Get-AvmRepositoryMetadataBackfillContext -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter { -not $ReviewOnly -and -not $StableBranch }
    }

    It 'creates metadata without running unrelated formatters or managed-file changes' {
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $script:events | Should -Be @('clone', 'metadata')
        Should -Invoke Remove-AvmMetadataFileConflict -Times 0
        Should -Invoke Set-TerraformCodeowners -Times 0
        Should -Invoke Resolve-AvmManagedFilesUpgradeDecision -Times 0
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $ReviewOnly -and $VerifyCandidate -and $StableBranch -ceq 'avm-bot/module-metadata-backfill' -and
            $ExpectedActor.id -eq 187664033 -and $Title -notmatch '\[skip ci\]'
        }
        $result.BackfillReviewUrl | Should -Be 'https://github.com/Azure/example/pull/43'
    }

    It 'keeps a metadata dry run from requesting publication' {
        $script:parameters.planOnly = $true
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $result.BackfillReviewUrl | Should -BeNullOrEmpty
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter { $PlanOnly -and $ReviewOnly -and -not $State.UpdateSource }
    }

    It 'defers existing reviews and branches without overwriting them: <Existing>' -TestCases @(
        @{ Existing = 'review' }, @{ Existing = 'branch' }
    ) {
        param($Existing)
        $script:existingReview = $Existing -eq 'review'
        $script:existingBranch = $Existing -eq 'branch'
        (Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true).BackfillDeferred | Should -BeTrue
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'rejects non-manual metadata activation: <Event>' -TestCases @(
        @{ Event = 'schedule' }, @{ Event = 'repository_dispatch' }, @{ Event = 'push' }, @{ Event = 'workflow_run' }
    ) {
        param($Event)
        $env:GITHUB_EVENT_NAME = $Event
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*manual-only*'
        Should -Invoke Invoke-RepositoryGitHub -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'requires explicit metadata creation before source changes are permitted' {
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataUpdateSource $true } | Should -Throw '*requires explicit metadataBackfill*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }
}
