BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:originalModulePath = $env:PSModulePath
    $script:originalToken = $env:GH_TOKEN
    $env:PSModulePath = @(
        (Join-Path $script:repoRoot 'src')
        (Join-Path $PSHOME 'Modules')
    ) -join [System.IO.Path]::PathSeparator
    $shared = Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
    $codeowners = Join-Path $script:repoRoot 'repository-management' 'bicep-codeowners-sync'
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    foreach ($name in @('RepositoryFileSync.ps1', 'AvmPreCommit.ps1', 'ManagedFilesUpgrade.ps1')) {
        . (Join-Path $shared $name)
    }
    . (Join-Path $codeowners 'scripts' 'lib' 'Codeowners.ps1')
    . (Join-Path $codeowners 'scripts' 'lib' 'CodeownersSync.ps1')
    $script:template = Get-Content -LiteralPath (Join-Path $codeowners 'CODEOWNERS.template') -Raw
    $script:content = $script:template.Replace('__AVM_MODULE_OWNERS__', '/avm/res/test/module/ @alice @Azure/azure-verified-modules-module-owners')
    $script:snapshot = [pscustomobject]@{
        Content = $script:content
        BlobSha = Get-RepositoryGitBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes($script:content))
        SourceSha = 'f' * 40
        ModuleCount = 1
    }
    function New-CoreActor {
        [pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }
    }

    function New-CorePullRequest {
        [pscustomobject]@{
            number = 123
            html_url = "https://github.com/$($script:state.Repo.full_name)/pull/123"
            user = New-CoreActor
            merged_by = New-CoreActor
            auto_merge = $script:state.AutoMerge
            state = if ($script:state.Merged) { 'closed' } else { 'open' }
            merged = $script:state.Merged
            draft = $false
            merge_commit_sha = 'd' * 40
            changed_files = $script:state.RemotePaths.Count
            base = [pscustomobject]@{ ref = 'main'; sha = $script:state.MainSha; repo = $script:state.Repo }
            head = [pscustomobject]@{ ref = $script:state.Branch; sha = $script:state.RemoteHead; repo = $script:state.Repo }
        }
    }

    function Invoke-CoreApi {
        param([string] $Endpoint)
        $script:state.ApiCalls.Add($Endpoint)
        switch -Regex ($Endpoint) {
            '^installation/' { return [pscustomobject]@{ total_count = 1; repositories = @($script:state.Repo) } }
            '^repos/[^/]+/[^/]+$' { return $script:state.Repo }
            '/pulls\?' {
                if ($script:state.HasPullRequest -and -not $script:state.Merged) { return [pscustomobject]@{ number = 123 } }
                return @()
            }
            '/pulls/7343$' { return [pscustomobject]@{ merged = $true; base = @{ ref = 'main'; repo = $script:state.Repo } } }
            '/pulls/123$' { return New-CorePullRequest }
            '/pulls/123/files\?' { return @($script:state.RemotePaths | ForEach-Object { [pscustomobject]@{ filename = $_ } }) }
            '/codeowners/errors\?' { return [pscustomobject]@{ errors = @($script:state.OwnerErrors) } }
            '/commits/' {
                $sha = $Endpoint.Split('/')[-1]
                $actor = if ($script:state.HumanHead -and $sha -ceq ('b' * 40)) {
                    [pscustomobject]@{ login = 'human'; id = 7; type = 'User' }
                } else { New-CoreActor }
                $tree = if ($sha -ceq ('b' * 40)) { $script:state.OldTree } elseif ($sha -ceq ('d' * 40)) { $script:state.MergedTree } else { '2' * 40 }
                return [pscustomobject]@{
                    sha = $sha; author = $actor; committer = $actor
                    commit = @{ tree = @{ sha = $tree } }
                    parents = @(@{ sha = 'a' * 40 })
                }
            }
            '/compare/' {
                if (-not $Endpoint.Contains('?')) { return [pscustomobject]@{ merge_base_commit = @{ sha = 'd' * 40 }; status = 'identical' } }
                return [pscustomobject]@{
                    base_commit = @{ sha = 'a' * 40 }
                    merge_base_commit = @{ sha = 'a' * 40 }
                    total_commits = 1
                    commits = @([pscustomobject]@{ sha = $script:state.RemoteHead; author = New-CoreActor; committer = New-CoreActor })
                    files = @($script:state.RemotePaths | ForEach-Object { [pscustomobject]@{ filename = $_ } })
                }
            }
            default { throw "Unmocked API endpoint: $Endpoint" }
        }
    }

    function Invoke-CoreGit {
        param([string[]] $Arguments, [string] $WorkingDirectory, [int] $MaxRetries = 0)
        $script:state.GitCalls.Add($Arguments)
        if ($Arguments[0] -eq 'clone') {
            $script:state.CloneRetries = $MaxRetries
            $root = $Arguments[-1]
            $script:state.Root = $root
            $null = New-Item -ItemType Directory -Path (Join-Path $root '.github') -Force
            [System.IO.File]::WriteAllText((Join-Path $root '.github' 'CODEOWNERS'), $script:content)
            [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), 'original')
            $script:state.LocalHead = 'a' * 40
            return ''
        }
        if ($Arguments -contains 'commit-tree') { $script:state.LocalHead = 'c' * 40; return $script:state.LocalHead }
        if ($Arguments -contains 'commit') { $script:state.LocalHead = 'c' * 40; return '' }
        switch ($Arguments[0]) {
            'config' { return '' }
            'sparse-checkout' { return '' }
            'checkout' {
                if ($Arguments -contains '-b') { $script:state.Branch = $Arguments[-1] }
                return ''
            }
            'fetch' { return '' }
            'update-ref' { return '' }
            'add' { return '' }
            'rev-parse' { return $script:state.LocalHead }
            'ls-tree' { return "100644 blob $('e' * 40)`t$($Arguments[-1])" }
            'status' { if ($script:state.NoChanges) { return '' }; return " M $($script:state.LocalPaths[0])" }
            'diff' { return ($script:state.LocalPaths -join [char]0) + [char]0 }
            'write-tree' { return '2' * 40 }
            'push' {
                if ($script:state.RejectPush) { throw 'non-fast-forward update rejected' }
                $script:state.RemoteHead = $script:state.LocalHead
                return ''
            }
            default { throw "Unmocked Git invocation: $($Arguments -join ' ')" }
        }
    }
}

AfterAll {
    $env:GH_TOKEN = $script:originalToken
    $env:PSModulePath = $script:originalModulePath
}

Describe 'Existing repository-sync publication core' -Tag Component {
    BeforeEach {
        $env:GH_TOKEN = 'offline-test-token'
        $script:state = @{
            Repo = [pscustomobject]@{ id = 42; full_name = 'Azure/bicep-registry-modules'; default_branch = 'main'; fork = $false; archived = $false; disabled = $false; allow_squash_merge = $true; permissions = @{ push = $true } }
            MainSha = 'a' * 40
            LocalHead = 'a' * 40
            RemoteHead = $null
            OldTree = '2' * 40
            MergedTree = '2' * 40
            Branch = $null
            HasPullRequest = $false
            Merged = $false
            AutoMerge = $null
            HumanHead = $false
            NoChanges = $false
            RejectPush = $false
            CloneRetries = -1
            PrBody = $null
            CleanupFailureEnabled = $false
            LocalPaths = @('.github/CODEOWNERS')
            RemotePaths = @('.github/CODEOWNERS')
            OwnerErrors = @()
            Root = $null
            GitCalls = [System.Collections.Generic.List[object]]::new()
            GhCalls = [System.Collections.Generic.List[object]]::new()
            ApiCalls = [System.Collections.Generic.List[string]]::new()
        }
        Mock Invoke-RepositoryGit { param($Arguments, $WorkingDirectory, $MaxRetries) Invoke-CoreGit @PSBoundParameters }
        Mock Invoke-RepositoryGitHubApi { param($Endpoint) Invoke-CoreApi $Endpoint }
        Mock Get-RepositoryBranchHead {
            param($Repository, $Branch)
            if ($Branch -eq 'main') { return $script:state.MainSha }
            $script:state.Branch = $Branch
            return $script:state.RemoteHead
        }
        Mock Invoke-RepositoryGitHub {
            param($Arguments, $AsJson, $MaxRetries)
            $script:state.GhCalls.Add($Arguments)
            if ($Arguments[0] -eq 'api') {
                return [pscustomobject]@{ data = @{ viewer = @{ login = 'azure-verified-modules[bot]'; databaseId = 187664033 } } }
            }
            if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'create') {
                $script:state.HasPullRequest = $true
                $script:state.PrBody = Get-Content -LiteralPath $Arguments[([array]::IndexOf($Arguments, '--body-file') + 1)] -Raw
                return "https://github.com/$($script:state.Repo.full_name)/pull/123"
            }
            if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'merge') {
                $script:state.Merged = $true
                $script:state.MainSha = 'd' * 40
                return ''
            }
            throw 'An unexpected remote command was attempted.'
        }
        Mock Get-AvmBicepCodeownersSnapshot { $script:snapshot }
        Mock Get-RepositoryFileAtCommit { [pscustomobject]@{ Content = $script:content; Sha = $script:snapshot.BlobSha } }
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $false; Reason = 'current pin' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'main.tf'), 'prepared')
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
    }

    It 'uses the original Terraform preparation and publication defaults through the shared core' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf')
        $script:state.RemotePaths = @('main.tf')
        $result = Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog @()
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeTrue
        $result.IssueLog | Should -HaveCount 0
        $script:state.Branch | Should -Match '^avm-bot/pre-commit-[0-9]{14}$'
        $script:state.Merged | Should -BeTrue
        $script:state.CloneRetries | Should -Be 5
        $clone = @($script:state.GitCalls | Where-Object { $_[0] -eq 'clone' })[0]
        $clone[0..5] | Should -Be @('clone', '--quiet', '--depth', '1', '--branch', 'main')
        $clone | Should -Not -Contain '--no-checkout'
        $clone | Should -Not -Contain '--filter=blob:none'
        $commit = @($script:state.GitCalls | Where-Object { $_ -contains 'commit' })[0]
        $commit | Should -Contain 'user.name=azure-verified-modules[bot]'
        $commit | Should -Contain 'user.email=1049636+azure-verified-modules[bot]@users.noreply.github.com'
        $commit[-2..-1] | Should -Be @('-m', 'chore: run avm pre-commit [skip ci]')
        $create = @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' })[0]
        $create | Should -Contain 'chore: run avm pre-commit [skip ci]'
        $create | Should -Contain '--base=main'
        $create | Should -Contain "--head=$($script:state.Branch)"
        $create | Should -Not -Contain '--no-maintainer-edit'
        $script:state.PrBody | Should -BeExactly @"
Automated ``avm pre-commit`` run from [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools).

This PR is opened and merged by the AVM bot. ``[skip ci]`` is set on the commit so downstream workflows are not retriggered.
"@
        $merge = @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' })[0]
        $merge | Should -Contain '--delete-branch'
        $merge | Should -Contain '--admin'
        $merge | Should -Contain '--squash'
        $merge | Should -Contain '--subject'
        $merge | Should -Contain 'chore: run avm pre-commit [skip ci]'
        $merge | Should -Contain '--body='
        $merge | Should -Contain '--match-head-commit'
        $merge | Should -Contain ('c' * 40)
        $script:state.ApiCalls | Should -HaveCount 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'merge' -and $MaxRetries -eq 5 }
        Test-Path -LiteralPath $script:state.Root | Should -BeFalse
    }

    It 'preserves Terraform plan-only behavior without opening or merging a candidate' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf')
        $script:state.RemotePaths = @('main.tf')
        $result = Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -issueLog @()
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeTrue
        $script:state.GhCalls | Should -HaveCount 0
        $script:state.ApiCalls | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'add' -or $_ -contains 'commit' }) | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'preserves Terraform no-change behavior and the caller issue array' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.NoChanges = $true
        $issues = @('existing issue')
        $result = Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog $issues
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeFalse
        [object]::ReferenceEquals($result.IssueLog, $issues) | Should -BeTrue
        $script:state.GhCalls | Should -HaveCount 0
        $script:state.ApiCalls | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'add' -or $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'propagates Terraform preparation and publication failures without reporting success' -ForEach @(
        'clone', 'prepare', 'commit', 'push', 'create', 'merge'
    ) {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf')
        $script:state.RemotePaths = @('main.tf')
        $script:failureStage = $_
        if ($_ -eq 'prepare') {
            Mock Invoke-AvmPreCommitWithUpgradeRetry { throw 'prepare failed' }
        } elseif ($_ -in @('clone', 'commit', 'push')) {
            Mock Invoke-RepositoryGit { throw "$script:failureStage failed" } -ParameterFilter { $Arguments -contains $script:failureStage }
        } else {
            Mock Invoke-RepositoryGitHub { throw "$script:failureStage failed" } -ParameterFilter { $Arguments -contains $script:failureStage }
        }
        { Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog @() } |
            Should -Throw "*Administrative corrective action is required*$script:failureStage failed*"
        $script:state.Merged | Should -BeFalse
        if ($script:state.Root) { Test-Path -LiteralPath $script:state.Root | Should -BeFalse }
    }

    It 'keeps cleanup failure as a warning without masking the Terraform outcome' -ForEach @($false, $true) {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.NoChanges = $true
        $script:state.CleanupFailureEnabled = $true
        Mock Remove-Item { throw [System.IO.IOException]::new('cleanup unavailable') } -ParameterFilter {
            $script:state.CleanupFailureEnabled -and $script:state.Root -and
            $LiteralPath -ceq (Split-Path -Parent $script:state.Root)
        }
        Mock Write-Warning {}
        if ($_) { Mock Invoke-AvmPreCommitWithUpgradeRetry { throw 'prepare failed' } }
        try {
            if ($_) {
                { Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/terraform-test' -defaultBranch main -issueLog @() } |
                    Should -Throw '*prepare failed*'
            } else {
                $result = Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/terraform-test' -defaultBranch main -issueLog @()
                $result.HasChanges | Should -BeFalse
            }
            Should -Invoke Write-Warning -Exactly 1 -ParameterFilter { $Message -like 'Failed to clean up*cleanup unavailable*' }
        } finally {
            $script:state.CleanupFailureEnabled = $false
            if ($script:state.Root) {
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Split-Path -Parent $script:state.Root) -Recurse -Force
            }
        }
    }

    It 'creates a CODEOWNERS plan using that same diff, Git, and candidate implementation without merging' {
        $result = Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly
        $result.Status | Should -Be 'Planned'
        $script:state.Branch | Should -Be 'avm-bot/bicep-codeowners-sync'
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'status' }) | Should -HaveCount 1
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'push' }) | Should -HaveCount 1
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' }) | Should -HaveCount 1
        @($script:state.GhCalls | Where-Object { $_ -contains 'merge' }) | Should -HaveCount 0
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Times 0
    }

    It 'merges CODEOWNERS with the shared app-bypass implementation pinned to the exact head' {
        (Invoke-AvmBicepCodeownersSync -Template $script:template).Status | Should -Be 'Merged'
        $merge = @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' })[0]
        $merge | Should -Contain '--admin'
        $merge | Should -Contain '--squash'
        $merge | Should -Contain '--match-head-commit'
        $merge | Should -Contain ('c' * 40)
        $merge | Should -Not -Contain '--delete-branch'
        $merge | Should -Not -Contain '--auto'
    }

    It 'does not publish anything when shared diff detection reports no changes' {
        $script:state.NoChanges = $true
        (Invoke-AvmBicepCodeownersSync -Template $script:template).Status | Should -Be 'NoChange'
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'reuses an identical stable candidate without a second commit, push, or creation' {
        $script:state.RemoteHead = 'b' * 40
        $script:state.HasPullRequest = $true
        (Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly).Status | Should -Be 'Planned'
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' -or $_ -contains 'commit' -or $_ -contains 'commit-tree' }) | Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }

    It 'updates a stable candidate as a descendant of both heads without checking out old head code' {
        $script:state.RemoteHead = 'b' * 40
        $script:state.HasPullRequest = $true
        $script:state.OldTree = '3' * 40
        (Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly).Status | Should -Be 'Planned'
        $commit = @($script:state.GitCalls | Where-Object { $_ -contains 'commit-tree' })[0]
        $commit | Should -Contain ('a' * 40)
        $commit | Should -Contain ('b' * 40)
        @($script:state.GitCalls | Where-Object { $_ -contains '--force' -or ($_[0] -eq 'checkout' -and $_ -contains ('b' * 40)) }) | Should -HaveCount 0
    }

    It 'rejects pre-enabled auto-merge before updating the existing candidate' {
        $script:state.RemoteHead = 'b' * 40
        $script:state.HasPullRequest = $true
        $script:state.AutoMerge = @{ merge_method = 'squash' }
        $script:state.OldTree = '3' * 40
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*auto-merge enabled*'
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'preserves human work on an existing candidate branch' {
        $script:state.RemoteHead = 'b' * 40
        $script:state.HumanHead = $true
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*expected app bot*'
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'rejects prepared changes outside the supplied file scope before publishing' {
        $script:state.LocalPaths += 'unrelated.ps1'
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*outside*'
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'checks the complete remote file scope before merging' {
        $script:state.RemotePaths += 'unrelated.ps1'
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*outside*'
        @($script:state.GhCalls | Where-Object { $_ -contains 'merge' }) | Should -HaveCount 0
    }

    It 'leaves a plan reviewable while surfacing GitHub owner diagnostics' {
        $script:state.OwnerErrors = @(@{ message = 'Unknown owner alice' })
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*candidate remains open*'
        $script:state.HasPullRequest | Should -BeTrue
        $script:state.Merged | Should -BeFalse
    }

    It 'propagates bypass failure instead of enabling auto-merge or using another credential' {
        Mock Invoke-RepositoryGitHub { throw '403 bypass denied' } -ParameterFilter { $Arguments -contains 'merge' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*403 bypass denied*'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'merge' -and $MaxRetries -eq 0 }
        $script:state.HasPullRequest | Should -BeTrue
    }

    It 'propagates non-fast-forward failures without forcing an update' {
        $script:state.RejectPush = $true
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*non-fast-forward*'
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }

    It 'rejects unexpected post-merge tree changes' {
        $script:state.MergedTree = '3' * 40
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*merged base or tree differs*'
    }

    It 'does not publish after a concurrent base update' {
        Mock Get-RepositoryBranchHead {
            if ($Branch -eq 'main') { return 'e' * 40 }
            $script:state.Branch = $Branch
            return $script:state.RemoteHead
        }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*moved before publishing*'
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'does not merge after a concurrent candidate-head update' {
        Mock Get-RepositoryBranchHead {
            if ($Branch -eq 'main') { return $script:state.MainSha }
            $script:state.Branch = $Branch
            if ($script:state.RemoteHead) { return 'e' * 40 }
            return $null
        }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*moved during validation*'
        @($script:state.GhCalls | Where-Object { $_ -contains 'merge' }) | Should -HaveCount 0
    }
}

Describe 'Original repository-sync preparation regressions' -Tag Component {
    It 'resolves the checkout module by name from the isolated source-only catalog' {
        $module = Import-Module Avm.Authoring -PassThru -ErrorAction Stop
        $module.Path | Should -BeExactly (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psm1')
    }

    It 'retains the standalone pre-commit result, metadata, and upgrade cases' {
        { & (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'Test-AvmPreCommit.ps1') } | Should -Not -Throw
    }

    It 'retains the original managed-file pin fallback and upgrade decisions' {
        { & (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'Test-ManagedFilesUpgrade.ps1') } | Should -Not -Throw
    }

    It 'keeps standalone input-contract checks valid after shared-library extraction' {
        { & (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'Test-RepositorySyncInputs.ps1') } | Should -Not -Throw
    }

    It 'loads the module before local Git in a fresh process with Actions mode <ActionsContext>' -ForEach @(
        @{ ActionsContext = 'false' }
        @{ ActionsContext = 'true' }
    ) {
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $child = @'
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = (Join-Path $env:SYNC_TEST_ROOT 'src') + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
if (Get-Module Avm.Authoring) { throw 'The child must start without Avm.Authoring loaded.' }
$available = @(Get-Module -ListAvailable Avm.Authoring)
if ($available.Count -ne 1 -or $available[0].Path -cne (Join-Path $env:SYNC_TEST_ROOT 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')) { throw 'The child module catalog is not isolated to the checkout.' }
. (Join-Path $env:SYNC_TEST_ROOT 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryFileSync.ps1')
if (Get-Command Invoke-AvmPreCommitForRepository -ErrorAction SilentlyContinue) { throw 'The shared library loaded the Terraform adapter.' }
if (-not (Get-Command Invoke-RepositoryFileSync -CommandType Function)) { throw 'The standalone shared core is missing.' }
. (Join-Path $env:SYNC_TEST_ROOT 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
function Invoke-RepositoryFileSync {
    param($Repository, $DefaultBranch, $PlanOnly, $State, $Prepare)
    $module = Get-Module Avm.Authoring
    if (-not $module) { throw 'Missing module before clone.' }
    if ($module.Path -cne (Join-Path $env:SYNC_TEST_ROOT 'src' 'Avm.Authoring' 'Avm.Authoring.psm1')) { throw 'The probe did not load the checkout module.' }
    $probe = Invoke-RepositorySyncProcess -Command git -Arguments @('--version')
    if ($probe.ExitCode -ne 0 -or $probe.StdOut -notmatch '^git version ') { throw 'Local Git transport failed.' }
    return @{ HasChanges = $false; Status = 'NoChange' }
}
$result = Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/offline-test' -defaultBranch main -issueLog @()
if ($result.HasChanges -or $result.Count -ne 2) { throw 'Unexpected legacy result.' }
'fresh-process-transport-ok'
'@
        $modulePath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psm1'
        $module = Get-Module Avm.Authoring | Where-Object { $_.Path -ceq $modulePath } | Select-Object -First 1
        $output = & $module {
            param($Executable, $Code, $Root, $ActionsMode)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Code) `
                -TimeoutSec 60 -EnvVars @{
                    SYNC_TEST_ROOT = $Root
                    PSModulePath = (Join-Path $Root 'src') + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
                    GITHUB_ACTIONS = $ActionsMode
                    GH_TOKEN = $null
                    GITHUB_TOKEN = $null
                }
        } $pwsh $child $script:repoRoot $ActionsContext
        $output.ExitCode | Should -Be 0
        $lines = @($output.StdOut.TrimEnd() -split '\r?\n')
        $lines[-1] | Should -BeExactly 'fresh-process-transport-ok'
        @($lines | Where-Object { $_ -ceq 'fresh-process-transport-ok' }) | Should -HaveCount 1
    }
}
