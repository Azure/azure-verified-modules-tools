#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $lib = Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'AvmPreCommit.ps1')
    . (Join-Path $repoRoot 'repository-management' 'module-metadata' 'MetadataBackfill.ps1')

    function Add-BackfillTestEvent {
        param([string] $Name)
        $events.Add($Name)
    }

    function git {
        $script:gitCalls.Add(@($args))
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'status') {
            if ($script:gitDirty) { ' M main.tf' }
        }
        elseif ($args[0] -notin @('checkout', 'add', 'push', '-c')) {
            throw "Unexpected stub git arguments: $args"
        }
    }

    function gh {
        if (($args -join ' ') -ne 'auth setup-git') {
            throw "Unexpected stub gh arguments: $args"
        }
        $global:LASTEXITCODE = 0
    }

    function Invoke-GitHubCliWithRetry {
        param(
            [hashtable[]] $commands,
            [string] $errorLog,
            [int] $maxRetries,
            [int] $retryDelayIncremental,
            [switch] $printOutputOnError,
            [switch] $returnOutput
        )
        $arguments = @($commands[0].Arguments)
        $script:githubCalls.Add($arguments)
        switch ("$($arguments[0]) $($arguments[1])") {
            'repo clone' {
                $path = $arguments[3].Trim('"')
                $null = New-Item -ItemType Directory -Path $path -Force
                [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'), "locals { example = true }`n")
                Add-BackfillTestEvent 'clone'
                return @{ success = $true; output = ''; exitCode = 0; error = '' }
            }
            'pr list' {
                $json = if ($script:existingReview) { '[{"number":42,"url":"https://github.com/Azure/example/pull/42"}]' } else { '[]' }
                return @{ success = $true; output = $json; exitCode = 0; error = '' }
            }
            'pr create' {
                return @{ success = $true; output = 'https://github.com/Azure/example/pull/43'; exitCode = 0; error = '' }
            }
            'pr merge' {
                return @{ success = $true; output = ''; exitCode = 0; error = '' }
            }
            default {
                if ($arguments[0] -eq 'api' -and $arguments[1] -like '*/git/matching-refs/heads/*') {
                    $json = if ($script:existingBranch) { '[{"ref":"refs/heads/avm-bot/module-metadata-backfill"}]' } else { '[]' }
                    return @{ success = $true; output = $json; exitCode = 0; error = '' }
                }
                throw "Unexpected stub GitHub arguments: $arguments"
            }
        }
    }

    function Resolve-AvmManagedFilesUpgradeDecision {
        param([string] $orgAndRepoName, [string] $repoRoot, [bool] $forceFileUpdate)
        $script:forceForwarded = $forceFileUpdate
        return @{ Upgrade = $false; Reason = 'unchanged' }
    }
}

Describe 'Component: metadata backfill repository sync' -Tag Component {
    BeforeEach {
        $script:gitCalls = [System.Collections.Generic.List[object]]::new()
        $script:githubCalls = [System.Collections.Generic.List[object]]::new()
        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:existingReview = $false
        $script:existingBranch = $false
        $script:gitDirty = $true
        $script:forceForwarded = $false
        $script:savedEnvironment = @{}
        foreach ($name in @('GITHUB_EVENT_NAME', 'TEMP', 'TMP', 'TMPDIR')) {
            $script:savedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $env:TEMP = $TestDrive
        $env:TMP = $TestDrive
        $env:TMPDIR = $TestDrive
        $script:adapter = Join-Path $TestDrive 'adapter.ps1'
        [System.IO.File]::WriteAllText($script:adapter, @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$RepositoryRoot, [string]$Repository, [string]$SeedManifestPath, [switch]$UpdateSource)
Add-BackfillTestEvent 'backfill'
[pscustomobject]@{
    Status = if ($WhatIfPreference) { 'planned' } else { 'pass' }
    RequestedWhatIf = $WhatIfPreference
    RequestedUpdateSource = $UpdateSource.IsPresent
    RepositoryRoot = $RepositoryRoot
    Repository = $Repository
    Modules = @([pscustomobject]@{ PlannedFiles = @('metadata.json') })
}
'@)
        Mock Get-AvmRepositoryMetadataBackfillContext {
            return @{ SeedPath = 'reviewed-seed.json'; ScriptPath = $script:adapter }
        }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            Add-BackfillTestEvent 'pre-commit'
            return [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
        $script:parameters = @{
            orgAndRepoName      = 'Azure/terraform-azurerm-avm-res-example-resource'
            repoId              = 'avm-res-example-resource'
            repositoryConfigDir = $TestDrive
            defaultBranch       = 'main'
            planOnly            = $false
            issueLog            = @()
        }
    }

    AfterEach {
        foreach ($name in $script:savedEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
    }

    It 'preserves ordinary sync defaults, skip-ci titles, and administrative auto-merge' {
        $null = Invoke-AvmPreCommitForRepository @script:parameters -forceFileUpdate $true
        Should -Invoke Get-AvmRepositoryMetadataBackfillContext -Times 0 -Exactly
        $script:events | Should -Be @('clone', 'pre-commit')
        $script:forceForwarded | Should -BeTrue
        $create = @($script:githubCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' })
        $create.Count | Should -Be 1
        ($create[0] -join ' ') | Should -Match '\[skip ci\]'
        $merges = @($script:githubCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' })
        $merges.Count | Should -Be 1
        $merges[0] | Should -Contain '--admin'
    }

    It 'backfills before pre-commit, forwards source opt-in, and never skips CI or auto-merges' {
        $result = @(Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true -metadataUpdateSource $true)[-1]
        $script:events | Should -Be @('clone', 'backfill', 'pre-commit')
        $result.MetadataBackfill.RequestedUpdateSource | Should -BeTrue
        $result.MetadataBackfill.RequestedWhatIf | Should -BeFalse
        $result.MetadataBackfill.Repository | Should -Be $script:parameters.orgAndRepoName
        $result.BackfillReviewUrl | Should -Be 'https://github.com/Azure/example/pull/43'
        $creates = @($script:githubCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' })
        $creates.Count | Should -Be 1
        ($creates[0] -join ' ') | Should -Match 'avm-bot/module-metadata-backfill'
        ($creates[0] -join ' ') | Should -Not -Match '\[skip ci\]'
        $commits = @($script:gitCalls | Where-Object { $_ -contains 'commit' })
        $commits.Count | Should -Be 1
        ($commits[0] -join ' ') | Should -Not -Match '\[skip ci\]'
        @($script:githubCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' }).Count | Should -Be 0
        @($script:gitCalls | Where-Object { $_ -contains '--force' }).Count | Should -Be 0
    }

    It 'plan-only forwards WhatIf and never commits, pushes, or opens a review' {
        $script:parameters.planOnly = $true
        $script:gitDirty = $false
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $result.HasChanges | Should -BeTrue
        $result.MetadataBackfill.RequestedWhatIf | Should -BeTrue
        $result.MetadataBackfill.RequestedUpdateSource | Should -BeFalse
        @($script:gitCalls | Where-Object { $_ -contains 'push' -or $_ -contains 'commit' }).Count | Should -Be 0
        @($script:githubCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -in @('create', 'merge') }).Count | Should -Be 0
    }

    It 'defers existing open backfill reviews and existing branches without updating them: <Existing>' -TestCases @(
        @{ Existing = 'review' }, @{ Existing = 'branch' }
    ) {
        param($Existing)
        $script:existingReview = $Existing -eq 'review'
        $script:existingBranch = $Existing -eq 'branch'
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $result.BackfillDeferred | Should -BeTrue
        $script:events.Count | Should -Be 0
        $script:gitCalls.Count | Should -Be 0
        @($script:githubCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -in @('create', 'merge') }).Count | Should -Be 0
    }

    It 'rejects non-manual activation before any external action: <Event>' -TestCases @(
        @{ Event = 'schedule' }, @{ Event = 'repository_dispatch' }
    ) {
        param($Event)
        $env:GITHUB_EVENT_NAME = $Event
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*manual-only*'
        $script:githubCalls.Count | Should -Be 0
        $script:gitCalls.Count | Should -Be 0
    }

    It 'does not enable backfill just because source wiring is requested' {
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataUpdateSource $true } | Should -Throw '*requires explicit metadataBackfill*'
        $script:githubCalls.Count | Should -Be 0
        $script:gitCalls.Count | Should -Be 0
    }

    It 'requires a released capability before querying target repositories' {
        Mock Get-AvmRepositoryMetadataBackfillContext { throw 'Publish/install a release with the shared metadata API.' }
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*Publish/install*'
        $script:githubCalls.Count | Should -Be 0
        $script:gitCalls.Count | Should -Be 0
        Mock Get-Command { $null } -ParameterFilter { $Module -eq 'Avm.Authoring' }
        { Assert-AvmMetadataBackfillCapability } | Should -Throw '*published Avm.Authoring release*'
    }
}
