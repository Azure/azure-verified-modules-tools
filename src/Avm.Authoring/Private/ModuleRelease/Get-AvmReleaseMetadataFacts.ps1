function Get-AvmReleaseMetadataFacts {
    <#
    .SYNOPSIS
        Read the facts that the release-metadata check needs about one pull request from GitHub.

    .DESCRIPTION
        Makes read-only GitHub API calls and returns the facts Test-AvmReleaseMetadata accepts. It never checks out or runs pull request code.

        - The pull request: author, title, description, and labels.
        - The changed files, read 100 at a time. When GitHub returns fewer files than the pull request reports, ChangedFiles is null, so the check treats the pull request as changing module code.
        - Who added each version label, read from the issue events. This runs only for bot pull requests that have a version label.
        - Whether each module-code file differs only in formatting. This runs only for bot pull requests where every module-code file was modified in place. It reads the file at the merge base and at the pull request head, and compares them with Test-AvmReleaseFormatEquivalence. It stops at the first difference.
        - The latest published version: the highest vMAJOR.MINOR.PATCH tag.

    .PARAMETER Repository
        The repository as 'owner/name'.

    .PARAMETER Number
        The pull request number.

    .EXAMPLE
        Get-AvmReleaseMetadataFacts -Repository 'Azure/terraform-azurerm-avm-res-example' -Number 42

        Returns the facts for pull request 42.

    .OUTPUTS
        Ordered dictionary with Number, Author, Title, Body, Labels, ChangedFiles, CurrentVersion, HeadSha, and BaseSha.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts names the release-metadata check input contract.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repository,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Number
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $pageSize = 100
    $maxPages = 30

    $pull = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/pulls/$Number"
    if ($null -eq $pull) {
        throw [AvmGitHubException]::new("GitHub returned no data for pull request #$Number in $Repository.", 0)
    }
    $author = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $pull -Name 'user') -Name 'login')
    $title = [string](Get-AvmPropertyValue -InputObject $pull -Name 'title')
    $body = [string](Get-AvmPropertyValue -InputObject $pull -Name 'body')
    $headSha = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $pull -Name 'head') -Name 'sha')
    $baseSha = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $pull -Name 'base') -Name 'sha')
    $expectedFiles = [int](Get-AvmPropertyValue -InputObject $pull -Name 'changed_files')
    $labelNames = @(@(Get-AvmPropertyValue -InputObject $pull -Name 'labels') |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-AvmPropertyValue -InputObject $_ -Name 'name') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $files = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le $maxPages; $page++) {
        $items = @(Invoke-AvmGitHubApi -Endpoint "repos/$Repository/pulls/$Number/files?per_page=$pageSize&page=$page")
        foreach ($item in $items) {
            $previous = [string](Get-AvmPropertyValue -InputObject $item -Name 'previous_filename')
            $files.Add([ordered]@{
                    Path             = [string](Get-AvmPropertyValue -InputObject $item -Name 'filename')
                    Status           = [string](Get-AvmPropertyValue -InputObject $item -Name 'status')
                    PreviousPath     = if ([string]::IsNullOrWhiteSpace($previous)) { $null } else { $previous }
                    FormatEquivalent = $false
                })
        }
        if ($items.Count -lt $pageSize) {
            break
        }
    }
    $changedFiles = $files.ToArray()
    if ($files.Count -lt $expectedFiles) {
        Write-AvmLog "release-metadata: GitHub listed $($files.Count) of $expectedFiles changed files, so the check treats the pull request as changing module code." -Level Warning | Out-Null
        $changedFiles = $null
    }

    $class = Get-AvmReleasePullRequestClass -Author $author -Title $title -ChangedFiles $changedFiles
    $isHuman = $class.Kind -eq 'Human'
    $versionLabels = @($labelNames | Where-Object { $policy.VersionLabels -contains $_.Trim().ToLowerInvariant() })

    $addedBy = @{}
    if (-not $isHuman -and $versionLabels.Count -gt 0) {
        for ($page = 1; $page -le $maxPages; $page++) {
            $events = @(Invoke-AvmGitHubApi -Endpoint "repos/$Repository/issues/$Number/events?per_page=$pageSize&page=$page")
            foreach ($issueEvent in $events) {
                if ([string](Get-AvmPropertyValue -InputObject $issueEvent -Name 'event') -ne 'labeled') {
                    continue
                }
                $name = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $issueEvent -Name 'label') -Name 'name')
                if ([string]::IsNullOrWhiteSpace($name)) {
                    continue
                }
                $addedBy[$name.Trim().ToLowerInvariant()] = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $issueEvent -Name 'actor') -Name 'login')
            }
            if ($events.Count -lt $pageSize) {
                break
            }
        }
    }
    $labels = @(foreach ($name in $labelNames) {
            $key = $name.Trim().ToLowerInvariant()
            $actor = $null
            if ($addedBy.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($addedBy[$key])) {
                $actor = $addedBy[$key]
            }
            [ordered]@{ Name = $name; AddedBy = $actor }
        })

    $moduleFiles = @($class.ModuleCodeFiles)
    $inPlace = $null -ne $changedFiles -and $moduleFiles.Count -gt 0 -and @($changedFiles | Where-Object { $moduleFiles -contains ($_.Path -replace '\\', '/') -and @('modified', 'changed') -notcontains $_.Status.ToLowerInvariant() }).Count -eq 0
    if (-not $isHuman -and $inPlace) {
        $compare = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/compare/$baseSha...$($headSha)?per_page=1"
        $mergeBase = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $compare -Name 'merge_base_commit') -Name 'sha')
        if ([string]::IsNullOrWhiteSpace($mergeBase)) {
            $mergeBase = $baseSha
        }
        $readContent = {
            param([string] $FilePath, [string] $Ref)
            $escaped = (($FilePath -replace '\\', '/') -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            $item = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/contents/$($escaped)?ref=$Ref" -AllowNotFound
            if ($null -eq $item -or $item -isnot [System.Collections.IDictionary]) {
                return $null
            }
            if ([string](Get-AvmPropertyValue -InputObject $item -Name 'encoding') -ne 'base64') {
                return $null
            }
            $encoded = ([string](Get-AvmPropertyValue -InputObject $item -Name 'content')) -replace '\s', ''
            return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
        }
        foreach ($file in $changedFiles) {
            if ($moduleFiles -notcontains ($file.Path -replace '\\', '/')) {
                continue
            }
            $baseContent = & $readContent -FilePath $file.Path -Ref $mergeBase
            $headContent = & $readContent -FilePath $file.Path -Ref $headSha
            $file.FormatEquivalent = [bool](Test-AvmReleaseFormatEquivalence -Path $file.Path -BaseContent $baseContent -HeadContent $headContent)
            if (-not $file.FormatEquivalent) {
                break
            }
        }
    }

    $currentVersion = $null
    $best = $null
    $refs = @(Invoke-AvmGitHubApi -Endpoint "repos/$Repository/git/matching-refs/tags/v" -AllowNotFound)
    foreach ($ref in $refs) {
        if ($null -eq $ref) {
            continue
        }
        $tag = ([string](Get-AvmPropertyValue -InputObject $ref -Name 'ref')) -replace '^refs/tags/', ''
        $match = [regex]::Match($tag, '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
        if (-not $match.Success) {
            continue
        }
        $version = [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
        if ($null -eq $best -or $version -gt $best) {
            $best = $version
            $currentVersion = $tag
        }
    }

    return [ordered]@{
        Number         = $Number
        Author         = $author
        Title          = $title
        Body           = $body
        Labels         = $labels
        ChangedFiles   = $changedFiles
        CurrentVersion = $currentVersion
        HeadSha        = $headSha
        BaseSha        = $baseSha
    }
}
