function Get-AvmCodeownersModule {
    [CmdletBinding()]
    param()

    $path = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psm1'))
    $modules = @(Get-Module -Name Avm.Authoring | Where-Object { $_.Path -ceq $path })
    if ($modules.Count -ne 1) {
        throw [System.InvalidOperationException]::new('Import Avm.Authoring from this trusted tools checkout before running CODEOWNERS automation.')
    }
    return $modules[0]
}

function Get-AvmCodeownersBlobSha {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)

    return & (Get-AvmCodeownersModule) {
        param([byte[]] $ContentBytes)
        Get-AvmGitBlobSha -Bytes $ContentBytes
    } $Bytes
}

function Invoke-AvmCodeownersGh {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $ArgumentList)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $executable = (Get-Command -Name gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $result = & (Get-AvmCodeownersModule) {
        param([string] $Executable, [string[]] $Arguments)
        Invoke-AvmProcess -FilePath $Executable -ArgumentList $Arguments -TimeoutSec 120 -EnvVars @{
            GH_HOST = 'github.com'
            GITHUB_TOKEN = $null
            GH_DEBUG = $null
            GH_PROMPT_DISABLED = '1'
        }
    } $executable $ArgumentList
    return $result.StdOut
}

function Invoke-AvmCodeownersApi {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT')] [string] $Method = 'GET',
        [hashtable] $Body
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $arguments = @(
        'api', '--hostname', 'github.com', '--method', $Method,
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint
    )
    $bodyPath = $null
    try {
        if ($null -ne $Body) {
            $bodyPath = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($bodyPath, ($Body | ConvertTo-Json -Depth 30 -Compress), [System.Text.UTF8Encoding]::new($false))
            $arguments += @('--input', $bodyPath)
        }
        if ($Method -ne 'GET' -and $Endpoint -ne 'graphql' -and -not $PSCmdlet.ShouldProcess($Endpoint, $Method)) {
            return
        }
        $json = Invoke-AvmCodeownersGh -ArgumentList $arguments
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw [System.IO.InvalidDataException]::new("GitHub returned an empty response for $Method $Endpoint.")
        }
        $response = $json | ConvertFrom-Json -Depth 100 -NoEnumerate -ErrorAction Stop
        if ($null -eq $response) {
            throw [System.IO.InvalidDataException]::new("GitHub returned null for $Method $Endpoint.")
        }
        if ($Endpoint -eq 'graphql' -and $response.PSObject.Properties['errors']) {
            throw [System.InvalidOperationException]::new("GitHub GraphQL failed: $($response.errors | ConvertTo-Json -Compress)")
        }
        return $response
    }
    finally {
        if ($bodyPath) {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction Stop
        }
    }
}

function Get-AvmCodeownersGitHubFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Azure/Azure-Verified-Modules', 'Azure/bicep-registry-modules')] [string] $Repository,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $Sha
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $file = Invoke-AvmCodeownersApi -Endpoint "repos/$Repository/contents/$($Path)?ref=$Sha"
    if ($file.type -cne 'file' -or $file.path -cne $Path -or $file.encoding -cne 'base64' -or
        $file.sha -cnotmatch '^[0-9a-f]{40}$' -or $file.size -le 0) {
        throw [System.IO.InvalidDataException]::new("GitHub did not return a complete regular file for $Repository/$Path.")
    }
    $bytes = [System.Convert]::FromBase64String($file.content)
    if ($bytes.Length -ne $file.size -or (Get-AvmCodeownersBlobSha -Bytes $bytes) -cne $file.sha) {
        throw [System.IO.InvalidDataException]::new("GitHub file size or blob SHA mismatch for $Repository/$Path.")
    }
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return [pscustomobject]@{ Content = $text; Sha = $file.sha }
}

function Get-AvmBicepCodeownersSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Template,
        [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceSha
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $SourceSha) {
        $source = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/Azure-Verified-Modules/commits/main'
        $SourceSha = $source.sha
    }
    if ($SourceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The official index commit is missing or invalid.')
    }
    $names = @{ res = 'BicepResourceModules.csv'; ptn = 'BicepPatternModules.csv'; utl = 'BicepUtilityModules.csv' }
    $indexes = @{}
    $indexShas = @{}
    foreach ($kind in @('res', 'ptn', 'utl')) {
        $file = Get-AvmCodeownersGitHubFile -Repository 'Azure/Azure-Verified-Modules' `
            -Path "docs/static/module-indexes/$($names[$kind])" -Sha $SourceSha
        $indexes[$kind] = $file.Content
        $indexShas[$kind] = $file.Sha
    }
    $content = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $Template
    return [pscustomobject]@{
        Content = $content
        SourceSha = $SourceSha
        IndexShas = $indexShas
        BlobSha = Get-AvmCodeownersBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes($content))
        ModuleCount = @($content.Split("`n") | Where-Object { $_ -cmatch '^/avm/(res|ptn|utl)/' }).Count
    }
}

function Assert-AvmCodeownersBot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $User)

    if ($User.login -cne 'azure-verified-modules[bot]' -or $User.id -ne 187664033 -or $User.type -cne 'Bot') {
        throw [System.InvalidOperationException]::new('The CODEOWNERS change is not owned by the expected AVM App bot.')
    }
}

function Get-AvmCodeownersBranchSha {
    [CmdletBinding()]
    param()

    Set-StrictMode -Version 3.0
    $references = @(Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/matching-refs/heads/avm-bot/bicep-codeowners-sync')
    foreach ($reference in $references) {
        if (-not $reference.ref.StartsWith('refs/heads/avm-bot/bicep-codeowners-sync', [System.StringComparison]::Ordinal) -or
            $reference.object.type -cne 'commit' -or $reference.object.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new('The stable CODEOWNERS branch lookup returned invalid references.')
        }
    }
    $branch = @($references | Where-Object { $_.ref -ceq 'refs/heads/avm-bot/bicep-codeowners-sync' })
    if ($branch.Count -eq 0) {
        return $null
    }
    if ($branch.Count -ne 1 -or $branch[0].object.type -cne 'commit' -or $branch[0].object.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The stable CODEOWNERS branch reference is invalid.')
    }
    return $branch[0].object.sha
}

function Get-AvmCodeownersBaseSha {
    [CmdletBinding()]
    param()

    $reference = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/ref/heads/main'
    if ($reference.ref -cne 'refs/heads/main' -or $reference.object.type -cne 'commit' -or
        $reference.object.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The target main branch reference is invalid.')
    }
    return $reference.object.sha
}

function Assert-AvmCodeownersChangedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Files,
        [switch] $AllowEmpty,
        [string] $ExpectedBlobSha
    )

    if ($AllowEmpty -and $Files.Count -eq 0) {
        return
    }
    if ($Files.Count -ne 1 -or $Files[0].filename -cne '.github/CODEOWNERS' -or
        $Files[0].status -cne 'modified' -or $Files[0].PSObject.Properties['previous_filename'] -or
        ($ExpectedBlobSha -and $Files[0].sha -cne $ExpectedBlobSha)) {
        throw [System.InvalidOperationException]::new('The entire change must modify only .github/CODEOWNERS, without renames, deletions, or unrelated files.')
    }
}

function Get-AvmCodeownersComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $BaseSha,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $HeadSha
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $first = $null
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $page = 1
    do {
        $comparison = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/compare/$BaseSha...$($HeadSha)?per_page=100&page=$page"
        if ($null -eq $first) {
            $first = $comparison
            Assert-AvmCodeownersChangedFiles -Files @($first.files) -AllowEmpty
        }
        if ($comparison.base_commit.sha -cne $BaseSha -or $comparison.total_commits -ne $first.total_commits -or
            $comparison.merge_base_commit.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new('The branch comparison changed or returned an invalid base.')
        }
        foreach ($commit in @($comparison.commits)) {
            if ($commit.sha -cnotmatch '^[0-9a-f]{40}$' -or -not $seen.Add($commit.sha)) {
                throw [System.IO.InvalidDataException]::new('The branch comparison returned duplicate or invalid commits.')
            }
            Assert-AvmCodeownersBot -User $commit.author
            Assert-AvmCodeownersBot -User $commit.committer
        }
        $page++
    } while (@($comparison.commits).Count -eq 100 -and $seen.Count -lt $first.total_commits)
    if ($seen.Count -ne $first.total_commits) {
        throw [System.IO.InvalidDataException]::new('GitHub returned incomplete branch commit history.')
    }
    return $first
}

function Assert-AvmCodeownersPullRequestIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [long] $RepositoryId,
        [string] $ExpectedHeadSha,
        [string] $ExpectedBaseSha,
        [switch] $Merged
    )

    Set-StrictMode -Version 3.0
    Assert-AvmCodeownersBot -User $PullRequest.user
    if ($PullRequest.PSObject.Properties['auto_merge'] -and $null -ne $PullRequest.auto_merge) {
        throw [System.InvalidOperationException]::new('The CODEOWNERS candidate already has auto-merge enabled; refusing to update or merge it. An operator must review that configuration first.')
    }
    $expectedState = if ($Merged) { 'closed' } else { 'open' }
    if ($PullRequest.number -le 0 -or $PullRequest.state -cne $expectedState -or $PullRequest.draft -or
        [bool]$PullRequest.merged -ne $Merged.IsPresent -or $PullRequest.maintainer_can_modify -or
        $PullRequest.base.ref -cne 'main' -or $PullRequest.base.repo.full_name -cne 'Azure/bicep-registry-modules' -or
        $PullRequest.base.repo.id -ne $RepositoryId -or $PullRequest.base.repo.default_branch -cne 'main' -or
        $PullRequest.head.ref -cne 'avm-bot/bicep-codeowners-sync' -or
        $PullRequest.head.repo.full_name -cne 'Azure/bicep-registry-modules' -or
        $PullRequest.head.repo.id -ne $RepositoryId -or $PullRequest.head.repo.fork -or
        $PullRequest.head.sha -cnotmatch '^[0-9a-f]{40}$' -or
        ($ExpectedHeadSha -and $PullRequest.head.sha -cne $ExpectedHeadSha) -or
        ($ExpectedBaseSha -and $PullRequest.base.sha -cne $ExpectedBaseSha) -or
        $PullRequest.html_url -cne "https://github.com/Azure/bicep-registry-modules/pull/$($PullRequest.number)") {
        throw [System.InvalidOperationException]::new('The CODEOWNERS pull request has an unexpected author, repository, base, head, or state.')
    }
}

function Assert-AvmCodeownersPullRequestChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Number,
        [Parameter(Mandatory)] [long] $RepositoryId,
        [Parameter(Mandatory)] [string] $BaseSha,
        [Parameter(Mandatory)] [string] $HeadSha,
        [Parameter(Mandatory)] [string] $TreeSha,
        [Parameter(Mandatory)] [object] $Snapshot,
        [Parameter(Mandatory)] [string] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $endpoint = "repos/Azure/bicep-registry-modules/pulls/$Number"
    $pullRequest = Invoke-AvmCodeownersApi -Endpoint $endpoint
    Assert-AvmCodeownersPullRequestIdentity -PullRequest $pullRequest -RepositoryId $RepositoryId `
        -ExpectedHeadSha $HeadSha -ExpectedBaseSha $BaseSha
    if ($pullRequest.changed_files -ne 1) {
        throw [System.InvalidOperationException]::new('The CODEOWNERS pull request must contain exactly one changed file.')
    }
    $files = [System.Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $batch = @(Invoke-AvmCodeownersApi -Endpoint "$endpoint/files?per_page=100&page=$page")
        $files.AddRange([object[]]$batch)
        $page++
    } while ($batch.Count -eq 100)
    Assert-AvmCodeownersChangedFiles -Files $files.ToArray() -ExpectedBlobSha $Snapshot.BlobSha
    $comparison = Get-AvmCodeownersComparison -BaseSha $BaseSha -HeadSha $HeadSha
    Assert-AvmCodeownersChangedFiles -Files @($comparison.files) -ExpectedBlobSha $Snapshot.BlobSha
    if ($comparison.merge_base_commit.sha -cne $BaseSha) {
        throw [System.InvalidOperationException]::new('The CODEOWNERS branch is not based on the expected current main commit.')
    }
    $commit = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/commits/$HeadSha"
    Assert-AvmCodeownersBot -User $commit.author
    Assert-AvmCodeownersBot -User $commit.committer
    if ($commit.sha -cne $HeadSha -or $commit.commit.tree.sha -cne $TreeSha) {
        throw [System.InvalidOperationException]::new('The generated CODEOWNERS commit tree changed.')
    }
    $file = Get-AvmCodeownersGitHubFile -Repository 'Azure/bicep-registry-modules' -Path '.github/CODEOWNERS' -Sha $HeadSha
    Assert-AvmCodeownersContent -Content $file.Content -Template $Template
    if ($file.Sha -cne $Snapshot.BlobSha -or $file.Content -cne $Snapshot.Content) {
        throw [System.InvalidOperationException]::new('The branch CODEOWNERS does not exactly match the generated contents.')
    }
    $errors = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/codeowners/errors?ref=$HeadSha"
    if (@($errors.errors).Count -ne 0) {
        throw [System.InvalidOperationException]::new("GitHub rejected CODEOWNERS syntax or owner access in https://github.com/Azure/bicep-registry-modules/pull/$Number; the candidate remains open: $($errors.errors | ConvertTo-Json -Compress)")
    }
    $latest = Invoke-AvmCodeownersApi -Endpoint $endpoint
    Assert-AvmCodeownersPullRequestIdentity -PullRequest $latest -RepositoryId $RepositoryId `
        -ExpectedHeadSha $HeadSha -ExpectedBaseSha $BaseSha
    if ((Get-AvmCodeownersBaseSha) -cne $BaseSha -or (Get-AvmCodeownersBranchSha) -cne $HeadSha) {
        throw [System.InvalidOperationException]::new('The target base or CODEOWNERS head moved during validation; rerun from fresh state.')
    }
}

function Merge-AvmCodeownersPullRequest {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [int] $Number,
        [Parameter(Mandatory)] [long] $RepositoryId,
        [Parameter(Mandatory)] [string] $BaseSha,
        [Parameter(Mandatory)] [string] $HeadSha,
        [Parameter(Mandatory)] [string] $TreeSha,
        [Parameter(Mandatory)] [object] $Snapshot,
        [Parameter(Mandatory)] [string] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $prerequisite = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/pulls/7343'
    if (-not $prerequisite.merged -or $prerequisite.base.ref -cne 'main' -or
        $prerequisite.base.repo.id -ne $RepositoryId -or
        $prerequisite.base.repo.full_name -cne 'Azure/bicep-registry-modules') {
        throw [System.InvalidOperationException]::new('Merge the compatibility prerequisite https://github.com/Azure/bicep-registry-modules/pull/7343 before enabling CODEOWNERS merging.')
    }
    Assert-AvmCodeownersPullRequestChange -Number $Number -RepositoryId $RepositoryId `
        -BaseSha $BaseSha -HeadSha $HeadSha -TreeSha $TreeSha -Snapshot $Snapshot -Template $Template
    $url = "https://github.com/Azure/bicep-registry-modules/pull/$Number"
    if (-not $PSCmdlet.ShouldProcess($url, 'Squash merge only the verified CODEOWNERS head using the AVM App approved bypass')) {
        return
    }
    $null = Invoke-AvmCodeownersGh -ArgumentList @(
        'pr', 'merge', "$Number", '--repo', 'Azure/bicep-registry-modules',
        '--squash', '--admin', '--match-head-commit', $HeadSha,
        '--subject', 'chore: sync Bicep module CODEOWNERS', '--body='
    )
    $merged = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/pulls/$Number"
    if (-not $merged.merged) {
        throw [System.InvalidOperationException]::new("The app bypass did not merge $url. Configure the existing app's approved bypass; no auto-merge, approval, or credential fallback will be attempted.")
    }
    Assert-AvmCodeownersPullRequestIdentity -PullRequest $merged -RepositoryId $RepositoryId -ExpectedHeadSha $HeadSha -Merged
    Assert-AvmCodeownersBot -User $merged.merged_by
    if ($merged.merge_commit_sha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.InvalidOperationException]::new('The approved app bypass did not return a merged commit; no approval or credential fallback will be attempted.')
    }
    $commit = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/commits/$($merged.merge_commit_sha)"
    if ($commit.sha -cne $merged.merge_commit_sha -or @($commit.parents).Count -ne 1 -or
        $commit.parents[0].sha -cne $BaseSha -or $commit.commit.tree.sha -cne $TreeSha) {
        throw [System.InvalidOperationException]::new('The merged tree or base differs from the verified CODEOWNERS change; inspect the concurrent update.')
    }
    Assert-AvmCodeownersChangedFiles -Files @($commit.files) -ExpectedBlobSha $Snapshot.BlobSha
    $mainSha = Get-AvmCodeownersBaseSha
    $ancestry = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/compare/$($merged.merge_commit_sha)...$mainSha"
    if ($ancestry.merge_base_commit.sha -cne $merged.merge_commit_sha -or $ancestry.status -notin @('ahead', 'identical')) {
        throw [System.InvalidOperationException]::new('The verified merge is no longer on target main.')
    }
    $file = Get-AvmCodeownersGitHubFile -Repository 'Azure/bicep-registry-modules' -Path '.github/CODEOWNERS' -Sha $mainSha
    if ($file.Sha -cne $Snapshot.BlobSha -or $file.Content -cne $Snapshot.Content) {
        throw [System.InvalidOperationException]::new('Target main does not contain the generated CODEOWNERS after merging.')
    }
    return $url
}

function Invoke-AvmBicepCodeownersSync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Template,
        [switch] $PlanOnly
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw [System.InvalidOperationException]::new('GH_TOKEN must be the existing AVM App installation token; cached credentials and human tokens are not accepted.')
    }
    $installation = Invoke-AvmCodeownersApi -Endpoint 'installation/repositories?per_page=100'
    if ($installation.total_count -ne 1 -or @($installation.repositories).Count -ne 1 -or
        $installation.repositories[0].full_name -cne 'Azure/bicep-registry-modules') {
        throw [System.InvalidOperationException]::new('The installation token must be scoped only to Azure/bicep-registry-modules.')
    }
    $viewer = Invoke-AvmCodeownersApi -Endpoint 'graphql' -Method POST -Body @{ query = '{ viewer { login databaseId } }' }
    if ($viewer.data.viewer.login -cne 'azure-verified-modules[bot]' -or $viewer.data.viewer.databaseId -ne 187664033) {
        throw [System.InvalidOperationException]::new('The authenticated identity is not the existing AVM App bot.')
    }
    $repository = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules'
    if ($repository.full_name -cne 'Azure/bicep-registry-modules' -or $repository.default_branch -cne 'main' -or
        $repository.id -ne $installation.repositories[0].id -or $repository.fork -or $repository.archived -or
        $repository.disabled -or -not $repository.allow_squash_merge -or -not $repository.permissions.push) {
        throw [System.InvalidOperationException]::new('The target repository, main branch, squash setting, or app write permissions are unexpected.')
    }
    $baseSha = Get-AvmCodeownersBaseSha
    $baseCommit = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/commits/$baseSha"
    if ($baseCommit.sha -cne $baseSha -or $baseCommit.commit.tree.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The target base commit tree is invalid.')
    }
    $baseFile = Get-AvmCodeownersGitHubFile -Repository 'Azure/bicep-registry-modules' -Path '.github/CODEOWNERS' -Sha $baseSha
    Assert-AvmCodeownersContent -Content $baseFile.Content -Template $Template -AllowLegacyDefault
    $snapshot = Get-AvmBicepCodeownersSnapshot -Template $Template
    $result = [pscustomobject]@{
        Status = 'NoChange'
        SourceSha = $snapshot.SourceSha
        ModuleCount = $snapshot.ModuleCount
        PullRequestUrl = $null
        HeadSha = $null
    }
    if ($baseFile.Sha -ceq $snapshot.BlobSha -and $baseFile.Content -ceq $snapshot.Content) {
        return $result
    }

    $headSha = Get-AvmCodeownersBranchSha
    $open = @(Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/pulls?state=open&head=Azure%3Aavm-bot%2Fbicep-codeowners-sync&per_page=100')
    if ($open.Count -gt 1 -or ($open.Count -eq 1 -and -not $headSha)) {
        throw [System.InvalidOperationException]::new('The stable CODEOWNERS branch has ambiguous or missing pull request state.')
    }
    $pullRequest = $null
    if ($open.Count -eq 1) {
        $number = [int]$open[0].number
        $pullRequest = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/pulls/$number"
        Assert-AvmCodeownersPullRequestIdentity -PullRequest $pullRequest -RepositoryId $repository.id -ExpectedHeadSha $headSha
    }
    $reuseHead = $false
    $treeSha = $null
    if ($headSha) {
        $tip = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/commits/$headSha"
        Assert-AvmCodeownersBot -User $tip.author
        Assert-AvmCodeownersBot -User $tip.committer
        $comparison = Get-AvmCodeownersComparison -BaseSha $baseSha -HeadSha $headSha
        $headFile = Get-AvmCodeownersGitHubFile -Repository 'Azure/bicep-registry-modules' -Path '.github/CODEOWNERS' -Sha $headSha
        Assert-AvmCodeownersContent -Content $headFile.Content -Template $Template -AllowLegacyDefault
        $reuseHead = $headFile.Content -ceq $snapshot.Content -and $headFile.Sha -ceq $snapshot.BlobSha -and
            $comparison.merge_base_commit.sha -ceq $baseSha
        $treeSha = $tip.commit.tree.sha
    }
    if (-not $PSCmdlet.ShouldProcess('Azure/bicep-registry-modules/.github/CODEOWNERS', 'Create or update the validated app-owned synchronization pull request')) {
        $result.Status = 'Preview'
        return $result
    }

    if (-not $reuseHead) {
        $tree = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/trees' -Method POST -Body @{
            base_tree = $baseCommit.commit.tree.sha
            tree = @(@{ path = '.github/CODEOWNERS'; mode = '100644'; type = 'blob'; content = $snapshot.Content })
        }
        if ($tree.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new('GitHub did not create the generated CODEOWNERS tree.')
        }
        $treeSha = $tree.sha
        $parents = @($baseSha)
        if ($headSha -and $headSha -cne $baseSha) {
            $parents += $headSha
        }
        $created = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/commits' -Method POST -Body @{
            message = 'chore: sync Bicep module CODEOWNERS'
            tree = $treeSha
            parents = $parents
        }
        if ($created.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new('GitHub did not create the generated CODEOWNERS commit.')
        }
        $commit = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/commits/$($created.sha)"
        Assert-AvmCodeownersBot -User $commit.author
        Assert-AvmCodeownersBot -User $commit.committer
        if ($commit.sha -cne $created.sha -or $commit.commit.tree.sha -cne $treeSha -or
            (Get-AvmCodeownersBaseSha) -cne $baseSha -or (Get-AvmCodeownersBranchSha) -cne $headSha) {
            throw [System.InvalidOperationException]::new('The generated commit, target main, or stable branch moved before the update.')
        }
        $reference = if ($headSha) {
            Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/refs/heads/avm-bot/bicep-codeowners-sync' `
                -Method PATCH -Body @{ sha = $created.sha; force = $false }
        } else {
            Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/refs' -Method POST `
                -Body @{ ref = 'refs/heads/avm-bot/bicep-codeowners-sync'; sha = $created.sha }
        }
        if ($reference.ref -cne 'refs/heads/avm-bot/bicep-codeowners-sync' -or $reference.object.sha -cne $created.sha) {
            throw [System.InvalidOperationException]::new('GitHub did not set the expected stable CODEOWNERS branch head.')
        }
        $headSha = $created.sha
    }

    $title = 'chore: sync Bicep module CODEOWNERS'
    $body = @"
Generated from the [official AVM module indexes](https://github.com/Azure/Azure-Verified-Modules/commit/$($snapshot.SourceSha))
using the [reviewed template](https://github.com/Azure/azure-verified-modules-tools/blob/main/repository-management/bicep-codeowners-sync/CODEOWNERS.template).

Only ``.github/CODEOWNERS`` changes. Each top-level module's primary and secondary owners are followed by the shared module-owners group.
Parent directory rules cover child modules recursively; no child-specific rows are generated.
Tooling ownership and final overrides are retained. Plan-only runs never merge.
"@
    $body = $body.Replace("`r`n", "`n")
    if ($null -eq $pullRequest) {
        $pullRequest = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/pulls' -Method POST -Body @{
            title = $title
            body = $body
            base = 'main'
            head = 'avm-bot/bicep-codeowners-sync'
            maintainer_can_modify = $false
        }
    } else {
        $number = [int]$pullRequest.number
        $pullRequest = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/pulls/$number"
        Assert-AvmCodeownersPullRequestIdentity -PullRequest $pullRequest -RepositoryId $repository.id -ExpectedHeadSha $headSha
        if ($pullRequest.title -cne $title -or $pullRequest.body -cne $body) {
            $pullRequest = Invoke-AvmCodeownersApi -Endpoint "repos/Azure/bicep-registry-modules/pulls/$number" `
                -Method PATCH -Body @{ title = $title; body = $body }
        }
    }
    Assert-AvmCodeownersPullRequestIdentity -PullRequest $pullRequest -RepositoryId $repository.id -ExpectedHeadSha $headSha
    $guard = @{
        Number = [int]$pullRequest.number
        RepositoryId = $repository.id
        BaseSha = $baseSha
        HeadSha = $headSha
        TreeSha = $treeSha
        Snapshot = $snapshot
        Template = $Template
    }
    $result.HeadSha = $headSha
    $result.PullRequestUrl = $pullRequest.html_url
    if ($PlanOnly) {
        Assert-AvmCodeownersPullRequestChange @guard
        $result.Status = 'Planned'
    } else {
        $result.PullRequestUrl = Merge-AvmCodeownersPullRequest @guard
        $result.Status = 'Merged'
    }
    return $result
}
