function Format-AvmReleaseMetadataSummary {
    <#
    .SYNOPSIS
        Render a release-metadata result as a Markdown job summary.

    .DESCRIPTION
        Builds the summary that the release-metadata workflow writes to the job page. A failure lists each problem with the exact fix. Warnings and notes follow. The text ends with a reminder that the check runs again when the labels or description change.

    .PARAMETER Result
        The result from Test-AvmReleaseMetadata.

    .PARAMETER PullRequest
        The pull request number, shown in the heading.

    .EXAMPLE
        Format-AvmReleaseMetadataSummary -Result (Test-AvmReleaseMetadata -Author 'alice' -Labels @('patch') -Body '- [ ] Breaking changes.') -PullRequest 42

        Returns Markdown that starts with '## Release metadata for #42: passed'.

    .OUTPUTS
        The Markdown text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [int] $PullRequest
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $escape = {
        param([string] $Text)
        return ($Text -replace '\|', '\|' -replace "`r?`n", ' ')
    }
    $passed = $Result.Status -eq 'pass'
    $target = ''
    if ($PullRequest -gt 0) {
        $target = " for #$PullRequest"
    }
    $label = 'none'
    if (@($Result.VersionLabels).Count -gt 0) {
        $label = (@($Result.VersionLabels) | ForEach-Object { "``$_``" }) -join ', '
    }
    $moduleCode = 'No'
    if ($Result.ModuleCodeChanged) {
        $moduleCode = if ($Result.FormattingOnly) { 'Formatting only' } else { 'Yes' }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## Release metadata$($target): $(if ($passed) { 'passed' } else { 'failed' })")
    $lines.Add('')
    $lines.Add('| Fact | Value |')
    $lines.Add('| --- | --- |')
    $lines.Add("| Pull request kind | $($Result.Kind) |")
    $lines.Add("| Version label | $label |")
    $lines.Add("| Breaking change | $(if ($Result.BreakingChange) { 'Yes' } else { 'No' }) |")
    $lines.Add("| Module code changed | $moduleCode |")
    $lines.Add("| Triggers a release | $(if ($Result.TriggersRelease) { 'Yes' } else { 'No' }) |")

    if (-not $passed) {
        $lines.Add('')
        $lines.Add('### How to fix')
        $lines.Add('')
        foreach ($issue in @($Result.Issues)) {
            $lines.Add("- **$($issue.Code)**: $(& $escape -Text $issue.Message) $(& $escape -Text $issue.Remedy)")
        }
    }
    if (@($Result.Warnings).Count -gt 0) {
        $lines.Add('')
        $lines.Add('### Warnings')
        $lines.Add('')
        foreach ($warning in @($Result.Warnings)) {
            $lines.Add("- $(& $escape -Text $warning)")
        }
    }
    if (@($Result.Notes).Count -gt 0) {
        $lines.Add('')
        $lines.Add('### Notes')
        $lines.Add('')
        foreach ($note in @($Result.Notes)) {
            $lines.Add("- $(& $escape -Text $note)")
        }
    }
    $lines.Add('')
    $lines.Add('This check runs again when the labels, description, or commits change. You do not need to push a new commit.')
    return ($lines -join "`n") + "`n"
}
