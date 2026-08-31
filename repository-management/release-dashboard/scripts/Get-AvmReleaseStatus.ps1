<#
.SYNOPSIS
    Collects release and managed-file version status for every AVM Terraform module repository.

.DESCRIPTION
    Writes a single JSON document describing, per repository:
      - the managed-files version it is pinned to
      - its newest published release
      - how many commits sit on the default branch beyond that release
      - how many of those are human-authored rather than automation
      - how old the oldest unreleased human commit is

    Every field comes from the GitHub API. Nothing is inferred.
#>
[CmdletBinding()]
param(
    [string]$Owner = 'Azure',
    [string]$RepoPattern = 'terraform-azurerm-avm-',
    [string]$OutputPath = "$PSScriptRoot/../site/data/release-status.json",
    [int]$MaxRepos = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GhJson {
    param([string]$Path, [string]$Jq, [string]$Method, [hashtable]$Fields)
    $arguments = @('api')
    if ($Method) { $arguments += @('-X', $Method) }
    $arguments += $Path
    # Query strings long enough to need encoding go through -f rather than the path,
    # which is what the search endpoints require.
    if ($Fields) { foreach ($key in $Fields.Keys) { $arguments += @('-f', "$key=$($Fields[$key])") } }
    if ($Jq) { $arguments += @('--jq', $Jq) }
    $raw = & gh @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw -join "`n") | ConvertFrom-Json } catch { return $null }
}

function Get-AvmRepoName {
    param([string]$Owner, [string]$Pattern)
    $found = & gh search repos --owner $Owner $Pattern --limit 300 --json 'name,isArchived' 2>$null | ConvertFrom-Json
    return @($found |
        Where-Object { -not $_.isArchived -and $_.name -like "$Pattern*" } |
        Select-Object -ExpandProperty name |
        Sort-Object -Unique)
}

function Get-PinnedVersion {
    param([string]$Repo)
    # The contents API returns base64, not JSON, so this bypasses Invoke-GhJson.
    $encoded = & gh api "repos/$Repo/contents/.avm/managed-files-version.json" --jq '.content' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $encoded) { return $null }
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($encoded -join '') -replace '\s', '')))
        return ($decoded | ConvertFrom-Json).version
    } catch { return $null }
}

function Get-NewestVersion {
    <#
        The Terraform registry publishes from git tags, not GitHub releases, so the
        tag list is the authority on what a consumer can actually install. Three AVM
        repositories carry a version tag with no matching release: aks-economy,
        aks-enterprise and certificateregistration-certificateorder. Reading releases
        alone reports those as never published, while the registry serves them.

        Releases are still read, because they carry a publication date that a tag
        does not. When the newest tag has no release, the date comes from the commit
        the tag points at.
    #>
    param([string]$Repo)

    $tags = Invoke-GhJson -Path "repos/$Repo/tags?per_page=100"
    if ($null -eq $tags) { return $null }

    $versions = foreach ($tag in @($tags)) {
        $text = ($tag.name -replace '^v', '')
        # Ignore pre-release and non-semver tags; the registry does not serve them.
        if ($text -notmatch '^\d+\.\d+\.\d+$') { continue }
        [pscustomobject]@{ Name = $tag.name; Version = [version]$text; Sha = $tag.commit.sha }
    }
    $versions = @($versions)
    if ($versions.Count -eq 0) { return $null }

    $newest = $versions | Sort-Object Version | Select-Object -Last 1

    $published = $null
    $releases = Invoke-GhJson -Path "repos/$Repo/releases?per_page=100"
    if ($null -ne $releases) {
        $match = @($releases | Where-Object { $_.tag_name -eq $newest.Name -and -not $_.draft }) | Select-Object -First 1
        if ($match) { $published = $match.published_at }
    }
    if (-not $published) {
        # gh --jq emits a bare string here, not JSON, so this bypasses Invoke-GhJson
        # for the same reason Get-PinnedVersion does.
        $commitDate = & gh api "repos/$Repo/commits/$($newest.Sha)" --jq '.commit.committer.date' 2>$null
        if ($LASTEXITCODE -eq 0 -and $commitDate) { $published = ($commitDate -join '').Trim() }
    }

    return [pscustomobject]@{ Tag = $newest.Name; Published = $published }
}

function Get-AwaitingReleaseIssue {
    <#
        AVM defines "Status: Awaiting Release To Be Cut :scissors:" to mean a fix has
        merged but no release carries it yet. That is the same condition this script
        computes from tags, so the issues belong beside the commit counts.

        One org-wide search returns every match with its repository, which costs a
        single call rather than one per repository.
    #>
    param([string]$Owner)

    $query = "org:$Owner is:issue is:open label:`"Status: Awaiting Release To Be Cut :scissors:`""
    $found = Invoke-GhJson -Path 'search/issues' -Method 'GET' -Fields @{ q = $query; per_page = '100' }

    $byRepo = @{}
    if ($null -eq $found -or -not ($found.PSObject.Properties.Name -contains 'items')) { return $byRepo }

    foreach ($item in @($found.items)) {
        $repoName = ($item.repository_url -split '/')[-1]
        if (-not $byRepo.ContainsKey($repoName)) { $byRepo[$repoName] = [System.Collections.Generic.List[object]]::new() }
        $byRepo[$repoName].Add([pscustomobject]@{
                number = $item.number
                title  = $item.title
                url    = $item.html_url
            })
    }
    return $byRepo
}

$repoNames = @(Get-AvmRepoName -Owner $Owner -Pattern $RepoPattern)
if ($MaxRepos -gt 0) { $repoNames = @($repoNames | Select-Object -First $MaxRepos) }
Write-Host "Found $($repoNames.Count) repositories"

$awaitingByRepo = Get-AwaitingReleaseIssue -Owner $Owner
Write-Host "Found awaiting-release issues in $($awaitingByRepo.Keys.Count) repositories"

$records = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($name in $repoNames) {
    $index++
    $repo = "$Owner/$name"
    Write-Host "[$index/$($repoNames.Count)] $name"

    $meta = Invoke-GhJson -Path "repos/$repo" -Jq '{default_branch, html_url}'
    $defaultBranch = if ($meta) { $meta.default_branch } else { 'main' }

    $record = [ordered]@{
        module                 = $name -replace '^terraform-azurerm-', ''
        repo                   = $name
        url                    = if ($meta) { $meta.html_url } else { "https://github.com/$repo" }
        pinnedVersion          = Get-PinnedVersion -Repo $repo
        latestTag              = $null
        latestPublished        = $null
        aheadBy                = 0
        automationAhead        = 0
        humanAhead             = 0
        oldestHumanDays        = $null
        unreleasedPrs          = @()
        awaitingReleaseIssues  = @(if ($awaitingByRepo.ContainsKey($name)) { $awaitingByRepo[$name] } else { })
        state                  = 'unknown'
    }

    $release = Get-NewestVersion -Repo $repo
    if ($null -eq $release) {
        $record.state = 'never-released'
        $records.Add([pscustomobject]$record)
        continue
    }

    $record.latestTag = $release.Tag
    $record.latestPublished = $release.Published

    $comparison = Invoke-GhJson -Path "repos/$repo/compare/$($release.Tag)...$defaultBranch"
    if ($null -eq $comparison -or -not ($comparison.PSObject.Properties.Name -contains 'commits')) {
        $record.state = 'compare-failed'
        $records.Add([pscustomobject]$record)
        continue
    }

    $record.aheadBy = [int]$comparison.ahead_by
    $commits = @($comparison.commits)

    # Author separates real work from automation far better than commit subject does.
    # "fix: grept apply" appears as both a bot commit and a human one, so no subject
    # pattern splits them; the account that pushed it always does.
    #
    # The test is a regex rather than -like, because -like reads "[bot]" as a
    # character class. '*[bot]' therefore matches any login ending in b, o or t,
    # and never matches the literal suffix, which silently counts every bot as human.
    $humanCommits = @($commits | Where-Object {
            $login = if ($_.author) { $_.author.login } else { $null }
            $login -and $login -notmatch '\[bot\]$'
        })
    $record.humanAhead = $humanCommits.Count
    $record.automationAhead = $commits.Count - $humanCommits.Count

    if ($humanCommits.Count -gt 0) {
        $oldest = ($humanCommits | ForEach-Object { [datetime]$_.commit.committer.date } | Sort-Object | Select-Object -First 1)
        $record.oldestHumanDays = [int][math]::Round(((Get-Date).ToUniversalTime() - $oldest).TotalDays, 0)

        # Squash merges rewrite commit SHAs, so a merge_commit_sha recorded on the pull
        # request often is not the commit that reached the default branch. The trailing
        # "(#123)" that squashing writes into the subject survives, so the subject is the
        # reliable link back to the pull request.
        $seen = [System.Collections.Generic.HashSet[int]]::new()
        $pullRequests = [System.Collections.Generic.List[object]]::new()
        foreach ($commit in $humanCommits) {
            $subject = ($commit.commit.message -split "`n")[0]
            if ($subject -notmatch '\(#(\d+)\)\s*$') { continue }
            $number = [int]$Matches[1]
            if (-not $seen.Add($number)) { continue }
            $pullRequests.Add([pscustomobject]@{
                    number = $number
                    title  = ($subject -replace '\s*\(#\d+\)\s*$', '')
                    author = $commit.author.login
                    url    = "https://github.com/$repo/pull/$number"
                    date   = $commit.commit.committer.date
                })
        }
        $record.unreleasedPrs = @($pullRequests | Sort-Object number)
    }

    $record.state = if ($record.humanAhead -gt 0) { 'unreleased-work' }
    elseif ($record.aheadBy -gt 0) { 'automation-only' }
    else { 'current' }

    $records.Add([pscustomobject]$record)
}

$document = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    repoCount   = $records.Count
    modules     = $records
}

$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
[IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath"
