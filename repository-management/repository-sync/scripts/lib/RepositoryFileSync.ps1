. (Join-Path $PSScriptRoot 'RetryHelpers.ps1')
. (Join-Path $PSScriptRoot 'RepoTree.ps1')

function Assert-RepositorySyncActor {
    param([AllowNull()] [object] $Actor, [AllowNull()] [object] $ExpectedActor)

    if ($ExpectedActor -and (-not $Actor -or $Actor.login -cne $ExpectedActor.login -or
        $Actor.id -ne $ExpectedActor.id -or $Actor.type -cne $ExpectedActor.type)) {
        throw [System.InvalidOperationException]::new('The repository synchronization candidate is not owned by the expected app bot.')
    }
}

function Assert-RepositorySyncFileScope {
    param([AllowEmptyCollection()] [string[]] $Paths, [string[]] $AllowedPaths, [string[]] $ExpectedPaths)

    $actual = [System.Collections.Generic.HashSet[string]]::new([string[]]$Paths, [System.StringComparer]::Ordinal)
    if ($AllowedPaths.Count -gt 0) {
        $allowed = [System.Collections.Generic.HashSet[string]]::new([string[]]$AllowedPaths, [System.StringComparer]::Ordinal)
        if (-not $allowed.IsSupersetOf($actual)) {
            throw [System.InvalidOperationException]::new('Repository synchronization contains changes outside its allowed file scope.')
        }
    }
    if ($null -ne $ExpectedPaths -and -not $actual.SetEquals([string[]]$ExpectedPaths)) {
        throw [System.InvalidOperationException]::new('The remote changed-file scope differs from the prepared repository changes.')
    }
}

function Assert-RepositorySyncPullRequest {
    param([hashtable] $Context, [object] $PullRequest, [switch] $Merged)

    Set-StrictMode -Version 3.0
    Assert-RepositorySyncActor -Actor $PullRequest.user -ExpectedActor $Context.ExpectedActor
    if ($PullRequest.auto_merge) {
        throw [System.InvalidOperationException]::new('The candidate already has auto-merge enabled; review that configuration before synchronizing.')
    }
    $state = if ($Merged) { 'closed' } else { 'open' }
    if ($PullRequest.state -cne $state -or [bool]$PullRequest.merged -ne $Merged.IsPresent -or $PullRequest.draft -or
        $PullRequest.base.ref -cne $Context.DefaultBranch -or $PullRequest.base.repo.default_branch -cne $Context.DefaultBranch -or
        $PullRequest.base.repo.id -ne $Context.Repository.id -or
        $PullRequest.base.repo.full_name -cne $Context.Repository.full_name -or
        $PullRequest.head.ref -cne $Context.Branch -or $PullRequest.head.repo.id -ne $Context.Repository.id -or
        $PullRequest.head.repo.full_name -cne $Context.Repository.full_name -or $PullRequest.head.repo.fork -or
        $PullRequest.head.sha -cne $Context.HeadSha -or
        $PullRequest.html_url -cne "https://github.com/$($Context.Repository.full_name)/pull/$($PullRequest.number)") {
        throw [System.InvalidOperationException]::new('The synchronization pull request has an unexpected repository, author, branch, head, or state.')
    }
}

function Get-RepositorySyncComparison {
    param([hashtable] $Context, [string] $HeadSha)

    Set-StrictMode -Version 3.0
    $page = 1
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $first = $null
    do {
        $value = Invoke-RepositoryGitHubApi -Endpoint "repos/$($Context.Repository.full_name)/compare/$($Context.BaseSha)...$($HeadSha)?per_page=100&page=$page"
        if ($null -eq $first) { $first = $value }
        if ($value.base_commit.sha -cne $Context.BaseSha -or $value.total_commits -ne $first.total_commits) {
            throw [System.IO.InvalidDataException]::new('GitHub returned inconsistent comparison data.')
        }
        foreach ($commit in @($value.commits)) {
            if ($commit.sha -cnotmatch '^[0-9a-f]{40}$' -or -not $seen.Add($commit.sha)) {
                throw [System.IO.InvalidDataException]::new('GitHub returned duplicate comparison commits.')
            }
            Assert-RepositorySyncActor -Actor $commit.author -ExpectedActor $Context.ExpectedActor
            Assert-RepositorySyncActor -Actor $commit.committer -ExpectedActor $Context.ExpectedActor
        }
        $page++
    } while (@($value.commits).Count -eq 100 -and $seen.Count -lt $first.total_commits)
    if ($seen.Count -ne $first.total_commits) {
        throw [System.IO.InvalidDataException]::new('GitHub returned incomplete comparison history.')
    }
    $paths = @($first.files | ForEach-Object { $_.filename; if ($_.PSObject.Properties['previous_filename']) { $_.previous_filename } })
    Assert-RepositorySyncFileScope -Paths $paths -AllowedPaths $Context.AllowedPaths
    return $first
}

function Assert-RepositorySyncCandidate {
    param([hashtable] $Context)

    Set-StrictMode -Version 3.0
    $repo = $Context.Repository.full_name
    $pull = Invoke-RepositoryGitHubApi -Endpoint "repos/$repo/pulls/$($Context.PullRequest.number)"
    Assert-RepositorySyncPullRequest -Context $Context -PullRequest $pull
    $files = [System.Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $batch = @(Invoke-RepositoryGitHubApi -Endpoint "repos/$repo/pulls/$($pull.number)/files?per_page=100&page=$page")
        $files.AddRange([object[]]$batch)
        $page++
    } while ($batch.Count -eq 100)
    if ($files.Count -ne $pull.changed_files) {
        throw [System.IO.InvalidDataException]::new('GitHub returned incomplete pull request file data.')
    }
    $paths = @($files | ForEach-Object { $_.filename; if ($_.PSObject.Properties['previous_filename']) { $_.previous_filename } })
    Assert-RepositorySyncFileScope -Paths $paths -AllowedPaths $Context.AllowedPaths -ExpectedPaths $Context.ChangedPaths
    $comparison = Get-RepositorySyncComparison -Context $Context -HeadSha $Context.HeadSha
    $commit = Invoke-RepositoryGitHubApi -Endpoint "repos/$repo/commits/$($Context.HeadSha)"
    Assert-RepositorySyncActor -Actor $commit.author -ExpectedActor $Context.ExpectedActor
    Assert-RepositorySyncActor -Actor $commit.committer -ExpectedActor $Context.ExpectedActor
    if ($commit.sha -cne $Context.HeadSha -or $commit.commit.tree.sha -cne $Context.TreeSha -or
        $comparison.merge_base_commit.sha -cne $Context.BaseSha -or $pull.base.sha -cne $Context.BaseSha) {
        throw [System.InvalidOperationException]::new('The candidate no longer matches the prepared base, head, or tree.')
    }
    $Context.PullRequest = $pull
    $Context.Phase = 'Candidate'
    if ($Context.ValidateChange) { & $Context.ValidateChange $Context }
    $latest = Invoke-RepositoryGitHubApi -Endpoint "repos/$repo/pulls/$($pull.number)"
    Assert-RepositorySyncPullRequest -Context $Context -PullRequest $latest
    if ((Get-RepositoryBranchHead -Repository $repo -Branch $Context.DefaultBranch) -cne $Context.BaseSha -or
        (Get-RepositoryBranchHead -Repository $repo -Branch $Context.Branch) -cne $Context.HeadSha) {
        throw [System.InvalidOperationException]::new('The synchronization base or head moved during validation.')
    }
}

function Invoke-RepositoryFileSync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository,
        [Parameter(Mandatory)] [string] $DefaultBranch,
        [switch] $PlanOnly,
        [switch] $ReviewOnly,
        [scriptblock] $Prepare,
        [hashtable] $GeneratedFiles = @{},
        [string[]] $AllowedPaths = @(),
        [switch] $FullCheckout,
        [string] $StableBranch,
        [switch] $KeepBranch,
        [switch] $VerifyCandidate,
        [object] $ExpectedActor,
        [scriptblock] $ValidateChange,
        [hashtable] $State = @{},
        [string] $Title = 'chore: run avm pre-commit [skip ci]',
        [string] $CommitMessage,
        [string] $Body = @"
Automated ``avm pre-commit`` run from [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools).

This PR is opened and merged by the AVM bot. ``[skip ci]`` is set on the commit so downstream workflows are not retriggered.
"@
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $result = @{ HasChanges = $false; Status = 'NoChange'; PullRequestUrl = $null; HeadSha = $null }
    if (-not $PSCmdlet.ShouldProcess($Repository, 'Prepare repository synchronization changes')) {
        $result.Status = 'Preview'
        return $result
    }
    if ($StableBranch -and -not $ExpectedActor) {
        throw [System.ArgumentException]::new('Stable synchronization branches require an expected app actor.')
    }
    if (($StableBranch -or $ExpectedActor -or $ValidateChange) -and -not $VerifyCandidate) {
        throw [System.ArgumentException]::new('Stable branches, expected actors, and validation hooks require candidate verification.')
    }
    if ($ExpectedActor) {
        if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
            throw [System.InvalidOperationException]::new('Repository synchronization requires an explicit app installation token.')
        }
        $installation = Invoke-RepositoryGitHubApi -Endpoint 'installation/repositories?per_page=100'
        $viewer = Invoke-RepositoryGitHub -AsJson -Arguments @('api', 'graphql', '--raw-field', 'query={ viewer { login databaseId } }')
        if ($installation.total_count -ne 1 -or @($installation.repositories).Count -ne 1 -or
            $installation.repositories[0].full_name -cne $Repository -or
            $viewer.data.viewer.login -cne $ExpectedActor.login -or $viewer.data.viewer.databaseId -ne $ExpectedActor.id) {
            throw [System.InvalidOperationException]::new('The authenticated app or its target-only token scope is unexpected.')
        }
    }
    $repo = [pscustomobject]@{ full_name = $Repository }
    if ($VerifyCandidate) {
        $repo = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository"
        if ($repo.full_name -cne $Repository -or $repo.default_branch -cne $DefaultBranch -or $repo.fork -or $repo.archived -or $repo.disabled) {
            throw [System.InvalidOperationException]::new('The synchronization target or default branch is unexpected.')
        }
        if ($ExpectedActor -and $repo.id -ne $installation.repositories[0].id) {
            throw [System.InvalidOperationException]::new('The synchronization target repository ID does not match the app installation.')
        }
    }
    $parent = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-pre-commit-" + [guid]::NewGuid().ToString('n'))
    $root = Join-Path $parent 'repository'
    $null = New-Item -ItemType Directory -Path $parent
    try {
        $clone = @('clone', '--quiet', '--depth', '1', '--branch', $DefaultBranch)
        $sparseCheckout = $AllowedPaths.Count -gt 0 -and -not $FullCheckout
        if ($sparseCheckout) { $clone += @('--filter=blob:none', '--no-checkout') }
        $null = Invoke-RepositoryGit -Arguments ($clone + @("https://github.com/$Repository.git", $root)) -WorkingDirectory $parent -MaxRetries 5
        if ($sparseCheckout) {
            $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments (@('sparse-checkout', 'set', '--no-cone', '--') + $AllowedPaths)
            $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('checkout', '--quiet', $DefaultBranch)
        }
        $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('config', '--local', 'credential.helper', '!gh auth git-credential')
        $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('config', '--local', 'core.hooksPath', (Join-Path $parent 'disabled-hooks'))
        $baseSha = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('rev-parse', 'HEAD')
        if ($baseSha -cnotmatch '^[0-9a-f]{40}$') { throw [System.IO.InvalidDataException]::new('Invalid synchronization base SHA.') }
        $context = @{
            Repository = $repo; Root = $root; BaseSha = $baseSha; DefaultBranch = $DefaultBranch
            AllowedPaths = $AllowedPaths; ExpectedActor = $ExpectedActor; ValidateChange = $ValidateChange
            State = $State; PlanOnly = $PlanOnly.IsPresent; Phase = 'Base'
        }
        if ($ValidateChange) { & $ValidateChange $context }
        Push-Location $root
        try {
            if ($Prepare) { & $Prepare $context }
            foreach ($path in $GeneratedFiles.Keys) {
                if ($path -cmatch '(^/|\\|(^|/)\.\.?(/|$)|(^|/)\.git(/|$)|[\r\n])') {
                    throw [System.ArgumentException]::new('Generated files must use repository-relative paths without traversal.')
                }
                Assert-RepositorySyncFileScope -Paths @($path) -AllowedPaths $AllowedPaths
                $entry = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('ls-tree', 'HEAD', '--', $path)
                if ($entry -cnotmatch '^100(?:644|755) blob [0-9a-f]{40}\t') {
                    throw [System.IO.InvalidDataException]::new('Generated-file synchronization requires an existing regular target file.')
                }
                $destination = Join-Path $root $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                [System.IO.File]::WriteAllText($destination, [string]$GeneratedFiles[$path], [System.Text.UTF8Encoding]::new($false))
            }
            $status = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('status', '--porcelain')
            $result.HasChanges = -not [string]::IsNullOrWhiteSpace($status)
            if (-not $result.HasChanges) { return $result }
            Write-Host $status
            if ($PlanOnly) { $result.Status = 'Planned'; return $result }
            $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('add', '--all')
            $paths = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('diff', '--cached', '--no-renames', '--name-only', '-z')
            $context.ChangedPaths = @($paths.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
            Assert-RepositorySyncFileScope -Paths $context.ChangedPaths -AllowedPaths $AllowedPaths
            $context.TreeSha = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('write-tree')
            $branch = if ($StableBranch) { $StableBranch } else { 'avm-bot/pre-commit-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') }
            $context.Branch = $branch
            $oldHead = $null
            $open = @()
            if ($StableBranch) {
                $oldHead = Get-RepositoryBranchHead -Repository $Repository -Branch $branch
                $owner = $Repository.Split('/')[0]
                $headFilter = [uri]::EscapeDataString("${owner}:$branch")
                $open = @(Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/pulls?state=open&head=$headFilter&per_page=100")
            }
            if ($open.Count -gt 1 -or ($open.Count -eq 1 -and -not $oldHead)) {
                throw [System.InvalidOperationException]::new('The candidate branch or open pull request state is ambiguous.')
            }
            $context.HeadSha = $oldHead
            $context.PullRequest = $null
            if ($open.Count -eq 1) {
                $context.PullRequest = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/pulls/$($open[0].number)"
                Assert-RepositorySyncPullRequest -Context $context -PullRequest $context.PullRequest
            }
            $reuseHead = $false
            if ($oldHead) {
                $tip = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/commits/$oldHead"
                Assert-RepositorySyncActor -Actor $tip.author -ExpectedActor $ExpectedActor
                Assert-RepositorySyncActor -Actor $tip.committer -ExpectedActor $ExpectedActor
                $comparison = Get-RepositorySyncComparison -Context $context -HeadSha $oldHead
                $context.Phase = 'Existing'
                if ($ValidateChange) { & $ValidateChange $context }
                $reuseHead = $tip.commit.tree.sha -ceq $context.TreeSha -and $comparison.merge_base_commit.sha -ceq $baseSha
            }
            if (-not $reuseHead) {
                $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('checkout', '--quiet', '-b', $branch)
                $author = 'azure-verified-modules[bot]'
                $email = if ($ExpectedActor) { "$($ExpectedActor.id)+$($ExpectedActor.login)@users.noreply.github.com" } else { '1049636+azure-verified-modules[bot]@users.noreply.github.com' }
                $identity = @('-c', "user.name=$author", '-c', "user.email=$email")
                $message = if ($CommitMessage) { $CommitMessage } else { $Title }
                if ($oldHead) {
                    $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('fetch', '--quiet', '--no-tags', 'origin', "refs/heads/$branch")
                    $headSha = Invoke-RepositoryGit -WorkingDirectory $root -Arguments ($identity + @('commit-tree', $context.TreeSha, '-p', $baseSha, '-p', $oldHead, '-m', $message))
                    $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('update-ref', "refs/heads/$branch", $headSha, $baseSha)
                } else {
                    $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments ($identity + @('commit', '--quiet', '-m', $message))
                    $headSha = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('rev-parse', 'HEAD')
                }
                if ($headSha -cnotmatch '^[0-9a-f]{40}$' -or
                    ($VerifyCandidate -and (
                        (Get-RepositoryBranchHead -Repository $Repository -Branch $DefaultBranch) -cne $baseSha -or
                        (Get-RepositoryBranchHead -Repository $Repository -Branch $branch) -cne $oldHead))) {
                    throw [System.InvalidOperationException]::new('The synchronization base or candidate moved before publishing.')
                }
                $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('push', '--quiet', '--set-upstream', 'origin', $branch)
                $context.HeadSha = $headSha
            }
            if (-not $context.PullRequest) {
                $bodyFile = Join-Path $parent 'pr-body.md'
                [System.IO.File]::WriteAllText($bodyFile, $Body.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
                $create = @(
                    'pr', 'create', "--repo=$Repository", "--base=$DefaultBranch", "--head=$branch",
                    '--title', $Title, '--body-file', $bodyFile
                )
                if ($VerifyCandidate) { $create += '--no-maintainer-edit' }
                $prUrl = Invoke-RepositoryGitHub -Arguments $create
                if ($prUrl -cnotmatch "^https://github.com/$([regex]::Escape($Repository))/pull/[0-9]+$") {
                    throw [System.IO.InvalidDataException]::new('GitHub did not return the expected candidate URL.')
                }
                $number = [int]($prUrl.Split('/')[-1])
                $context.PullRequest = [pscustomobject]@{ html_url = $prUrl; number = $number }
                if ($VerifyCandidate) {
                    $context.PullRequest = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/pulls/$number"
                }
            }
            $result.PullRequestUrl = $context.PullRequest.html_url
            $result.HeadSha = $context.HeadSha
            if ($VerifyCandidate) { Assert-RepositorySyncCandidate -Context $context }
            if ($ReviewOnly) { $result.Status = 'ReviewRequired'; return $result }
            if ($VerifyCandidate -and -not $repo.allow_squash_merge) { throw [System.InvalidOperationException]::new('Squash merging is unavailable on the synchronization target.') }
            $merge = @(
                'pr', 'merge', $result.PullRequestUrl, "--repo=$Repository", '--squash', '--admin',
                '--match-head-commit', $context.HeadSha, '--subject', $Title, '--body='
            )
            if (-not $KeepBranch) { $merge += '--delete-branch' }
            $retries = if ($ExpectedActor) { 0 } else { 5 }
            $null = Invoke-RepositoryGitHub -Arguments $merge -MaxRetries $retries
            if ($VerifyCandidate) {
                $merged = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/pulls/$($context.PullRequest.number)"
                Assert-RepositorySyncPullRequest -Context $context -PullRequest $merged -Merged
                Assert-RepositorySyncActor -Actor $merged.merged_by -ExpectedActor $ExpectedActor
                $commit = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/commits/$($merged.merge_commit_sha)"
                if (@($commit.parents).Count -ne 1 -or $commit.parents[0].sha -cne $baseSha -or $commit.commit.tree.sha -cne $context.TreeSha) {
                    throw [System.InvalidOperationException]::new('The merged base or tree differs from the verified synchronization candidate.')
                }
                $mainSha = Get-RepositoryBranchHead -Repository $Repository -Branch $DefaultBranch
                $ancestry = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/compare/$($merged.merge_commit_sha)...$mainSha"
                if ($ancestry.merge_base_commit.sha -cne $merged.merge_commit_sha -or $ancestry.status -notin @('ahead', 'identical')) {
                    throw [System.InvalidOperationException]::new('The verified synchronization merge is not on the target branch.')
                }
                $context.HeadSha = $mainSha
                $context.Phase = 'Merged'
                if ($ValidateChange) { & $ValidateChange $context }
            }
            $result.Status = 'Merged'
            return $result
        } finally { Pop-Location }
    } finally {
        if (Test-Path -LiteralPath $parent) {
            try {
                Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to clean up $parent : $($_.Exception.Message)"
            }
        }
    }
}
