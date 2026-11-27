function Invoke-AvmReleaseBranch {
    <#
    .SYNOPSIS
        Prepare a reviewed external fork pull request for credentialed E2E testing.

    .DESCRIPTION
        For an external fork pull request that requires credentialed E2E tests,
        an authorized FTE must first review all code, workflows, and dependencies
        that could access credentials on the current pull request head. The
        command cannot verify which commit was reviewed. It snapshots the head
        when invoked and refuses to merge if it changes during the handoff.
        Restrict write access to the release branch and review any later changes.
        Using the installed GitHub CLI and its existing github.com authentication,
        this command creates a release branch from upstream main, retargets the
        fork pull request, merges the captured head, and opens a follow-up pull
        request to main. The follow-up retains the original title, links to the
        original pull request, thanks its author, and preserves its description.
        It does not add labels, approve reviews, or bypass protections. Ordinary
        checks do not require this handoff.

        A failure can leave a branch or retargeted or merged pull request behind.
        Inspect their state before recovering manually; do not blindly rerun.

    .PARAMETER Repository
        Upstream github.com repository in owner/name form.

    .PARAMETER PullRequest
        Number of an open external fork pull request in the upstream repository.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check for a newer Avm.Authoring release.

    .PARAMETER WhatIf
        Validate and display the planned handoff without changing GitHub state.

    .PARAMETER Confirm
        Prompt before performing the handoff.

    .OUTPUTS
        PSCustomObject with Repository, OriginalPullRequest, ReleaseBranch,
        HeadCommit, and FollowUpPullRequestUrl.

    .EXAMPLE
        Invoke-AvmReleaseBranch `
            -Repository 'Azure/example' `
            -PullRequest 123 `
            -WhatIf

    .EXAMPLE
        avm release-branch `
            --repository Azure/example `
            --pull-request 123
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')]
        [string] $Repository,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $PullRequest,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($env:AVM_OFFLINE -eq '1') {
        throw [AvmConfigurationException]::new('AVM_OFFLINE=1 prevents the GitHub pull request handoff.')
    }
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $repo = Invoke-AvmGitHubApi -Endpoint "repos/$Repository"
    if ($repo['fork'] -ne $false -or $repo['default_branch'] -cne 'main' -or
        $repo['permissions']['push'] -ne $true) {
        throw [System.InvalidOperationException]::new(
            "The authenticated GitHub account must have write access to the non-fork upstream $Repository with default branch main.")
    }
    $mergeMethod = if ($repo['allow_squash_merge'] -eq $true) { 'squash' }
    elseif ($repo['allow_merge_commit'] -eq $true) { 'merge' }
    elseif ($repo['allow_rebase_merge'] -eq $true) { 'rebase' }
    else {
        throw [System.InvalidOperationException]::new("No supported merge method is enabled for $Repository.")
    }

    $endpoint = "repos/$Repository/pulls/$PullRequest"
    $pr = Invoke-AvmGitHubApi -Endpoint $endpoint
    if ($pr['state'] -cne 'open' -or $pr['draft'] -ne $false -or
        $pr['base']['repo']['full_name'] -ine $Repository -or
        $null -eq $pr['head']['repo'] -or $pr['head']['repo']['fork'] -ne $true -or
        $pr['head']['repo']['owner']['login'] -ieq $repo['owner']['login']) {
        throw [System.InvalidOperationException]::new(
            "Pull request $PullRequest must be open, ready for review, target the upstream repository, and originate from an external fork.")
    }
    $headCommit = [string]$pr['head']['sha']
    if ($headCommit -notmatch '^[a-fA-F0-9]{40}$') {
        throw [System.InvalidOperationException]::new('GitHub did not return a valid pull request head commit.')
    }
    $originalPullRequestUrl = [string]$pr['html_url']
    $expectedPullRequestUrl = "https://github.com/$Repository/pull/$PullRequest"
    if ($originalPullRequestUrl -ine $expectedPullRequestUrl) {
        throw [System.InvalidOperationException]::new('GitHub did not return the expected pull request URL.')
    }
    $originalAuthor = [string]$pr['user']['login']
    if ($originalAuthor -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?(?:\[bot\])?$') {
        throw [System.InvalidOperationException]::new('GitHub did not return a valid pull request author.')
    }

    $main = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/git/ref/heads/main"
    $mainSha = [string]$main['object']['sha']
    if ($mainSha -notmatch '^[a-fA-F0-9]{40}$') {
        throw [System.InvalidOperationException]::new('GitHub did not return a valid main commit.')
    }
    $branch = 'release/fork-pr-{0}-{1}' -f $PullRequest, $headCommit.Substring(0, 12).ToLowerInvariant()
    if (-not $PSCmdlet.ShouldProcess("$Repository pull request #$PullRequest",
            "Create $branch, retarget and merge fork head $headCommit, and open a pull request to main")) {
        return
    }

    $stage = 'creating the release branch'
    $followUpUrl = ''
    try {
        $null = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/git/refs" -Method POST -Body @{
            ref = "refs/heads/$branch"
            sha = $mainSha
        }
        $stage = 'retargeting the fork pull request'
        $null = Invoke-AvmGitHubApi -Endpoint $endpoint -Method PATCH -Body @{ base = $branch }
        $stage = 'checking the retargeted pull request'
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $current = Invoke-AvmGitHubApi -Endpoint $endpoint
            if ($current['state'] -cne 'open' -or $current['base']['ref'] -cne $branch -or
                $current['head']['sha'] -ine $headCommit) {
                throw [System.InvalidOperationException]::new(
                    'The pull request state, target, or captured head changed during the handoff.')
            }
            if ($current['mergeable_state'] -cne 'unknown') { break }
            if ($attempt -lt 9) { Start-Sleep -Seconds 2 }
        }
        # Unstable means mergeable with pending or failed statuses; the merge endpoint still enforces required protections.
        if ($current['mergeable'] -ne $true -or
            $current['mergeable_state'] -cnotin @('clean', 'unstable')) {
            throw [System.InvalidOperationException]::new(
                "GitHub reports mergeable_state '$($current['mergeable_state'])'. Resolve required checks, reviews, or conflicts without bypassing protections.")
        }

        $releaseRef = "repos/$Repository/git/ref/heads/$branch"
        $release = Invoke-AvmGitHubApi -Endpoint $releaseRef
        if ($release['object']['sha'] -ine $mainSha) {
            throw [System.InvalidOperationException]::new('The release branch changed before the fork merge.')
        }
        $stage = 'merging the fork pull request'
        $merge = Invoke-AvmGitHubApi -Endpoint "$endpoint/merge" -Method PUT -Body @{
            sha          = $headCommit
            merge_method = $mergeMethod
        }
        if ($merge['merged'] -ne $true -or $merge['sha'] -notmatch '^[a-fA-F0-9]{40}$') {
            throw [System.InvalidOperationException]::new('GitHub did not confirm the fork pull request was merged.')
        }
        $stage = 'verifying the merged release branch'
        $release = Invoke-AvmGitHubApi -Endpoint $releaseRef
        if ($release['object']['sha'] -ine $merge['sha']) {
            throw [System.InvalidOperationException]::new('The release branch no longer points to the reported merge commit.')
        }
        $stage = 'opening the follow-up pull request'
        $followUpBody = @(
            "Credentialed E2E follow-up for [$Repository#$PullRequest]($originalPullRequestUrl)"
            "(fork commit ``$headCommit``)."
        ) -join ' '
        $followUpBody += "`n`nThank you @$originalAuthor for your contribution."
        $originalBody = [string]$pr['body']
        if (-not [string]::IsNullOrEmpty($originalBody)) {
            $followUpBody += "`n`n$originalBody"
        }
        $followUp = Invoke-AvmGitHubApi -Endpoint "repos/$Repository/pulls" -Method POST -Body @{
            title = $pr['title']
            head  = $branch
            base  = 'main'
            body  = $followUpBody
        }
        if ([string]::IsNullOrWhiteSpace([string]$followUp['html_url'])) {
            throw [System.InvalidOperationException]::new('GitHub did not return the follow-up pull request URL.')
        }
        $followUpUrl = [string]$followUp['html_url']
        return [pscustomobject]@{
            Repository             = $Repository
            OriginalPullRequest    = $PullRequest
            ReleaseBranch          = $branch
            HeadCommit             = $headCommit
            FollowUpPullRequestUrl = $followUpUrl
        }
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Handoff stopped while $stage. Inspect $Repository pull request #$PullRequest and branch $branch before manual recovery; do not blindly rerun. $($_.Exception.Message)",
            $_.Exception)
    }
}
