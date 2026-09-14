#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'ManagedFilesUpgrade.ps1')

    function Add-BackfillTestEvent {
        param([string] $Name)
        $events.Add($Name)
    }
}

Describe 'Component: metadata backfill registration' -Tag Component {
    BeforeEach {
        $script:seed = Join-Path $TestDrive 'registered-seed.json'
        [System.IO.File]::WriteAllText($script:seed, '{"schemaVersion":1,"repository":"Azure/bicep-registry-modules","ecosystem":"bicep","reviewed":true,"modules":[]}')
        Mock Resolve-AvmMetadataBackfillSeedManifest { $script:seed }
    }

    It 'resolves Bicep seeds and the local adapter through the trusted module API' {
        $context = Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName 'Azure/bicep-registry-modules' -Ecosystem bicep
        $context.Manifest.ecosystem | Should -Be 'bicep'
        $context.ScriptPath | Should -Be ([System.IO.Path]::GetFullPath(
                (Join-Path $PSScriptRoot '..' '..' '..' 'repository-management' 'module-metadata' 'Invoke-ModuleMetadataBackfill.ps1')))
        Should -Invoke Resolve-AvmMetadataBackfillSeedManifest -Exactly 1 -ParameterFilter {
            $Repository -ceq 'Azure/bicep-registry-modules' -and (Test-Path -LiteralPath (Join-Path $ToolsRoot 'AGENTS.md'))
        }
    }

    It 'does not accept a Bicep registration for Terraform backfill' {
        { Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName 'Azure/bicep-registry-modules' } |
            Should -Throw '*reviewed terraform seed manifest*'
    }
}

Describe 'Component: metadata backfill repository sync' -Tag Component {
    BeforeEach {
        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:originalEvent = $env:GITHUB_EVENT_NAME
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:publication = @{}
        $script:existingReview = $false
        $script:existingBranch = $false
        $script:clone = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:clone
        $script:adapter = Join-Path $TestDrive 'adapter.ps1'
        [System.IO.File]::WriteAllText($script:adapter, @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$RepositoryRoot, [string]$Repository, [string]$SeedManifestPath, [switch]$UpdateSource)
Add-BackfillTestEvent 'backfill'
[System.IO.File]::WriteAllText((Join-Path $RepositoryRoot 'metadata.json'), '{}')
[pscustomobject]@{
    Status = 'pass'
    RequestedUpdateSource = $UpdateSource.IsPresent
    RepositoryRoot = $RepositoryRoot
    Repository = $Repository
    Modules = @([pscustomobject]@{ PlannedFiles = @('metadata.json') })
}
'@)
        Mock Import-Module {}
        Mock Get-AvmRepositoryMetadataBackfillContext {
            @{
                SeedPath = 'reviewed-seed.json'
                ScriptPath = $script:adapter
                Manifest = @{
                    modules = @(
                        @{ path = 'avm/res/test/module'; updateSource = $true }
                        @{ path = 'avm/res/test/module/child'; updateSource = $false }
                    )
                }
            }
        }
        Mock Invoke-RepositoryGitHub {
            if ($script:existingReview) {
                [pscustomobject]@{ number = 42; url = 'https://github.com/Azure/example/pull/42' }
            }
        }
        Mock Get-RepositoryBranchHead { if ($script:existingBranch) { 'a' * 40 } }
        Mock Invoke-RepositoryGit { throw 'Adapters must not bypass the shared publisher.' }
        Mock Invoke-RepositoryFileSync {
            param($Repository, $DefaultBranch, $PlanOnly, $Prepare, $State, $ReviewOnly)
            $script:publication = @{} + $PSBoundParameters
            Add-BackfillTestEvent 'clone'
            Push-Location $script:clone
            try {
                & $Prepare @{ Root = $script:clone; Repository = @{ full_name = $Repository }; State = $State; PlanOnly = [bool]$PlanOnly }
            }
            finally {
                Pop-Location
            }
            @{
                HasChanges = $true
                Status = if ($PlanOnly) { 'Planned' } elseif ($ReviewOnly) { 'ReviewRequired' } else { 'Merged' }
                PullRequestUrl = if ($PlanOnly) { $null } else { 'https://github.com/Azure/example/pull/43' }
                HeadSha = if ($PlanOnly) { $null } else { 'a' * 40 }
            }
        }
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $false; Reason = 'unchanged' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            Add-BackfillTestEvent 'pre-commit'
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
        $script:parameters = @{
            orgAndRepoName = 'Azure/terraform-azurerm-avm-res-example-resource'
            repoId = 'avm-res-example-resource'
            repositoryConfigDir = $TestDrive
            defaultBranch = 'main'
            planOnly = $false
            issueLog = @()
        }
    }

    AfterEach {
        $env:GITHUB_EVENT_NAME = $script:originalEvent
    }

    It 'preserves ordinary Terraform sync defaults and its exact legacy return shape' {
        $result = Invoke-AvmPreCommitForRepository @script:parameters -forceFileUpdate $true
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $script:events | Should -Be @('clone', 'pre-commit')
        Should -Invoke Get-AvmRepositoryMetadataBackfillContext -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter { -not $ReviewOnly -and -not $StableBranch -and -not $VerifyCandidate }
        Should -Invoke Resolve-AvmManagedFilesUpgradeDecision -Exactly 1 -ParameterFilter { $forceFileUpdate }
    }

    It 'prepares Terraform metadata before pre-commit and delegates review-only publication' {
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true -metadataUpdateSource $true
        $script:events | Should -Be @('clone', 'backfill', 'pre-commit')
        $result.MetadataBackfill.RequestedUpdateSource | Should -BeTrue
        $result.BackfillReviewUrl | Should -Be 'https://github.com/Azure/example/pull/43'
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $ReviewOnly -and $VerifyCandidate -and -not $PlanOnly -and
            $StableBranch -ceq 'avm-bot/module-metadata-backfill' -and
            $ExpectedActor.id -eq 187664033 -and $Title -notmatch '\[skip ci\]'
        }
        Should -Invoke Invoke-RepositoryGit -Times 0
    }

    It 'calculates Terraform plan changes in the disposable checkout without enabling publication' {
        $script:parameters.planOnly = $true
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $result.HasChanges | Should -BeTrue
        $result.BackfillReviewUrl | Should -BeNullOrEmpty
        $script:events | Should -Be @('clone', 'backfill', 'pre-commit')
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter { $PlanOnly -and $ReviewOnly }
    }

    It 'uses the same publisher for Bicep with a full checkout and an exact metadata/source allow-list' {
        $result = Invoke-AvmBicepMetadataBackfillSync -UpdateSource
        $result.Status | Should -Be 'ReviewRequired'
        $script:events | Should -Be @('clone', 'backfill')
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Times 0
        Should -Invoke Get-AvmRepositoryMetadataBackfillContext -Exactly 1 -ParameterFilter {
            $orgAndRepoName -ceq 'Azure/bicep-registry-modules' -and $Ecosystem -ceq 'bicep'
        }
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $ReviewOnly -and $VerifyCandidate -and $FullCheckout -and -not $PlanOnly -and
            $StableBranch -ceq 'avm-bot/bicep-metadata-backfill' -and
            $AllowedPaths.Count -eq 3 -and
            $AllowedPaths -ccontains 'avm/res/test/module/metadata.json' -and
            $AllowedPaths -ccontains 'avm/res/test/module/main.bicep' -and
            $AllowedPaths -ccontains 'avm/res/test/module/child/metadata.json'
        }
    }

    It 'keeps Bicep backfill plans read-only and source wiring disabled by default' {
        $result = Invoke-AvmBicepMetadataBackfillSync -PlanOnly
        $result.Status | Should -Be 'Planned'
        $result.PullRequestUrl | Should -BeNullOrEmpty
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $PlanOnly -and $ReviewOnly -and $AllowedPaths.Count -eq 2 -and -not $State.UpdateSource
        }
    }

    It 'defers existing metadata reviews or branches for either ecosystem: <Ecosystem>, <Existing>' -TestCases @(
        @{ Ecosystem = 'terraform'; Existing = 'review' }
        @{ Ecosystem = 'terraform'; Existing = 'branch' }
        @{ Ecosystem = 'bicep'; Existing = 'review' }
        @{ Ecosystem = 'bicep'; Existing = 'branch' }
    ) {
        param($Ecosystem, $Existing)
        $script:existingReview = $Existing -eq 'review'
        $script:existingBranch = $Existing -eq 'branch'
        if ($Ecosystem -eq 'bicep') {
            (Invoke-AvmBicepMetadataBackfillSync).Status | Should -Be 'Deferred'
        }
        else {
            (Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true).BackfillDeferred | Should -BeTrue
        }
        Should -Invoke Invoke-RepositoryFileSync -Times 0
        $script:events.Count | Should -Be 0
    }

    It 'rejects non-manual activation before external actions: <Event>' -TestCases @(
        @{ Event = 'schedule' }, @{ Event = 'repository_dispatch' }
    ) {
        param($Event)
        $env:GITHUB_EVENT_NAME = $Event
        { Invoke-AvmBicepMetadataBackfillSync } | Should -Throw '*manual-only*'
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*manual-only*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
        Should -Invoke Invoke-RepositoryGitHub -Times 0
    }

    It 'does not activate Terraform backfill merely because source wiring was requested' {
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataUpdateSource $true } | Should -Throw '*requires explicit metadataBackfill*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'requires reviewed seeds and a supported API before contacting the target' {
        Mock Get-AvmRepositoryMetadataBackfillContext { throw 'Publish/install a release with the shared metadata API.' }
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*Publish/install*'
        { Invoke-AvmBicepMetadataBackfillSync } | Should -Throw '*Publish/install*'
        Should -Invoke Invoke-RepositoryGitHub -Times 0
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }
}
