function Invoke-AvmReleaseMetadataCheck {
    <#
    .SYNOPSIS
        Run the release-metadata check for one Terraform module pull request in GitHub Actions.

    .DESCRIPTION
        Finds the pull request from the GitHub Actions event, reads its facts from GitHub, and checks them with Test-AvmReleaseMetadata. The check is read-only. It never checks out or runs pull request code, and it never adds labels.

        - pull_request and pull_request_target events: uses pull_request.number from the event file.
        - merge_group events: reads the pull request number from merge_group.head_ref, such as refs/heads/gh-readonly-queue/main/pr-42-<sha>.
        - Any other event: pass PullRequestNumber.

        It writes a job summary that tells the author how to fix each problem. Each problem is also logged as an error, and each warning as a warning. It returns the result and never throws because the check failed. The caller decides whether to fail the job.

        GitHub calls go through the GitHub CLI, so set GH_TOKEN to a token that can read the pull request, its issue events, and the repository contents.

    .PARAMETER Repository
        The repository as 'owner/name'. Defaults to the GITHUB_REPOSITORY environment variable.

    .PARAMETER EventName
        The GitHub Actions event name. Defaults to the GITHUB_EVENT_NAME environment variable.

    .PARAMETER EventPath
        The path to the GitHub Actions event file. Defaults to the GITHUB_EVENT_PATH environment variable.

    .PARAMETER PullRequestNumber
        The pull request to check. When set, the event isn't read.

    .PARAMETER SummaryPath
        The file that receives the Markdown job summary. Defaults to the GITHUB_STEP_SUMMARY environment variable. When empty, no summary is written.

    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check.

    .EXAMPLE
        $result = Invoke-AvmReleaseMetadataCheck -SkipModuleVersionCheck
        if ($result.Status -ne 'pass') { exit 1 }

        Checks the pull request from the current GitHub Actions event and fails the step when the check fails.

    .EXAMPLE
        Invoke-AvmReleaseMetadataCheck -Repository 'Azure/terraform-azurerm-avm-ptn-example-repo' -PullRequestNumber 42

        Checks pull request 42 from a local shell, using the GitHub CLI's token.

    .OUTPUTS
        The Test-AvmReleaseMetadata result, with Repository, PullRequest, and EventName added.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Repository = $env:GITHUB_REPOSITORY,

        [string] $EventName = $env:GITHUB_EVENT_NAME,

        [string] $EventPath = $env:GITHUB_EVENT_PATH,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $PullRequestNumber,

        [string] $SummaryPath = $env:GITHUB_STEP_SUMMARY,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    if ([string]::IsNullOrWhiteSpace($Repository) -or $Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw [System.ArgumentException]::new("Repository '$Repository' must be 'owner/name'. Pass -Repository or set GITHUB_REPOSITORY.")
    }

    $number = 0
    if ($PSBoundParameters.ContainsKey('PullRequestNumber')) {
        $number = $PullRequestNumber
    }
    else {
        if ([string]::IsNullOrWhiteSpace($EventPath) -or -not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
            throw [System.ArgumentException]::new("The event file '$EventPath' does not exist. Pass -PullRequestNumber or set GITHUB_EVENT_PATH.")
        }
        $payload = Get-Content -LiteralPath $EventPath -Raw | ConvertFrom-Json -AsHashtable
        switch ($EventName) {
            { $_ -in @('pull_request', 'pull_request_target') } {
                $number = [int](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $payload -Name 'pull_request') -Name 'number')
            }
            'merge_group' {
                $headRef = [string](Get-AvmPropertyValue -InputObject (Get-AvmPropertyValue -InputObject $payload -Name 'merge_group') -Name 'head_ref')
                $match = [regex]::Match($headRef, '^refs/heads/gh-readonly-queue/.+/pr-(\d+)-[0-9a-f]{40}$')
                if (-not $match.Success) {
                    throw [System.ArgumentException]::new("The merge group head ref '$headRef' does not name a pull request.")
                }
                $number = [int]$match.Groups[1].Value
            }
            default {
                throw [System.ArgumentException]::new("Event '$EventName' does not identify a pull request. Pass -PullRequestNumber.")
            }
        }
        if ($number -lt 1) {
            throw [System.ArgumentException]::new("The '$EventName' event file has no pull request number.")
        }
    }

    $facts = Get-AvmReleaseMetadataFacts -Repository $Repository -Number $number
    $result = Test-AvmReleaseMetadata -Author $facts.Author -Title $facts.Title -Body $facts.Body -Labels $facts.Labels -ChangedFiles $facts.ChangedFiles -CurrentVersion $facts.CurrentVersion -SkipModuleVersionCheck
    $result | Add-Member -NotePropertyName 'Repository' -NotePropertyValue $Repository
    $result | Add-Member -NotePropertyName 'PullRequest' -NotePropertyValue $number
    $result | Add-Member -NotePropertyName 'EventName' -NotePropertyValue $(if ([string]::IsNullOrWhiteSpace($EventName)) { $null } else { $EventName })

    if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
        $summary = Format-AvmReleaseMetadataSummary -Result $result -PullRequest $number
        Add-Content -LiteralPath $SummaryPath -Value $summary -Encoding utf8 -NoNewline
    }
    foreach ($issue in @($result.Issues)) {
        Write-AvmLog "release-metadata: $($issue.Message) $($issue.Remedy)" -Level Error | Out-Null
    }
    foreach ($warning in @($result.Warnings)) {
        Write-AvmLog "release-metadata: $warning" -Level Warning | Out-Null
    }
    $verdict = if ($result.Status -eq 'pass') { 'passed' } else { 'failed' }
    Write-AvmLog "release-metadata: $Repository#$number $verdict ($($result.Kind), version label: $(if ($result.VersionLabel) { $result.VersionLabel } else { 'none' }))." -Level Info | Out-Null

    return $result
}
