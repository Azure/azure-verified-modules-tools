function Format-AvmReleaseNotes {
    <#
    .SYNOPSIS
        Compose the release notes for a pending or cut-off release.

    .DESCRIPTION
        Builds the release notes in this order, leaving out empty parts:

        1. 'Breaking changes': one entry per breaking pull request, in the same format, sorted by number. A maintainer override replaces the entries. Entries for breaking pull requests that the override does not cover are appended below it, so a late breaking change is never hidden.
        2. 'Notes from maintainers': the maintainer commentary.
        3. "What's changed": one line per listed pull request, sorted by number.
        4. A full-changelog comparison link, when both versions are known.

    .PARAMETER BreakingEntries
        The breaking pull requests. Each entry has Number, WhatChanges, and RequiredUpgrade.

    .PARAMETER BreakingOverride
        The maintainer override, or null. It has Text and CoveredPullRequests.

    .PARAMETER Commentary
        The maintainer commentary, or null.

    .PARAMETER Changes
        The pull requests for the change list. Each entry has Number and Title.

    .PARAMETER Repository
        The repository as 'owner/name'.

    .PARAMETER PreviousVersion
        The previous version without a 'v' prefix, or null.

    .PARAMETER Version
        The new version without a 'v' prefix, or null.

    .EXAMPLE
        Format-AvmReleaseNotes -Changes @(@{ Number = 145; Title = 'fix: correct the default SKU' }) -Repository 'Azure/terraform-azurerm-avm-res-example' -PreviousVersion '0.8.2' -Version '0.8.3'

        Returns notes with a one-line change list and a comparison link.

    .OUTPUTS
        Ordered dictionary with Markdown, BreakingText (the body of the 'Breaking changes' section), and LateBreakingPullRequests.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Release notes is the GitHub release body name.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $BreakingEntries = @(),

        [AllowNull()]
        [object] $BreakingOverride,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Commentary,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Changes = @(),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Repository,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PreviousVersion,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Version
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy

    $indent = {
        param([string] $Value)
        $normalized = ConvertTo-AvmReleaseNormalizedText -Text $Value
        if ($normalized.Length -eq 0) {
            return $policy.MissingDetail
        }
        $lines = @($normalized -split "`n")
        $output = for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($index -eq 0 -or $lines[$index].Length -eq 0) {
                $lines[$index]
            }
            else {
                "  $($lines[$index])"
            }
        }
        return @($output) -join "`n"
    }

    $entries = @($BreakingEntries | Where-Object { $null -ne $_ } | Sort-Object -Property { [int](Get-AvmPropertyValue -InputObject $_ -Name 'Number') })
    $overrideText = ''
    $covered = @()
    if ($null -ne $BreakingOverride) {
        $overrideText = ConvertTo-AvmReleaseNormalizedText -Text ([string](Get-AvmPropertyValue -InputObject $BreakingOverride -Name 'Text'))
        $covered = @(Get-AvmPropertyValue -InputObject $BreakingOverride -Name 'CoveredPullRequests' | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    }

    $late = [System.Collections.Generic.List[int]]::new()
    $entryBlocks = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $number = [int](Get-AvmPropertyValue -InputObject $entry -Name 'Number')
        if ($overrideText.Length -gt 0 -and $covered -contains $number) {
            continue
        }
        if ($overrideText.Length -gt 0) {
            $late.Add($number)
        }
        $what = & $indent -Value ([string](Get-AvmPropertyValue -InputObject $entry -Name 'WhatChanges'))
        $upgrade = & $indent -Value ([string](Get-AvmPropertyValue -InputObject $entry -Name 'RequiredUpgrade'))
        $entryBlocks.Add("- **What changes:** $what (#$number)`n- **Required upgrade:** $upgrade")
    }

    $breakingParts = [System.Collections.Generic.List[string]]::new()
    if ($overrideText.Length -gt 0) {
        $breakingParts.Add($overrideText)
    }
    foreach ($block in $entryBlocks) {
        $breakingParts.Add($block)
    }
    $breakingText = $breakingParts -join "`n`n"

    $sections = [System.Collections.Generic.List[string]]::new()
    if ($breakingText.Length -gt 0) {
        $sections.Add("## $($policy.BreakingHeading)`n`n$breakingText")
    }

    $commentaryText = ConvertTo-AvmReleaseNormalizedText -Text $Commentary
    if ($commentaryText.Length -gt 0) {
        $sections.Add("## $($policy.CommentaryHeading)`n`n$commentaryText")
    }

    $changeLines = foreach ($change in @($Changes | Where-Object { $null -ne $_ } | Sort-Object -Property { [int](Get-AvmPropertyValue -InputObject $_ -Name 'Number') })) {
        $title = (([string](Get-AvmPropertyValue -InputObject $change -Name 'Title')) -replace '\s*[\r\n]+\s*', ' ').Trim()
        "- $title (#$([int](Get-AvmPropertyValue -InputObject $change -Name 'Number')))"
    }
    $changeLines = @($changeLines)
    if ($changeLines.Count -gt 0) {
        $sections.Add("## $($policy.ChangesHeading)`n`n$($changeLines -join "`n")")
    }

    if (-not [string]::IsNullOrWhiteSpace($PreviousVersion) -and -not [string]::IsNullOrWhiteSpace($Version)) {
        $sections.Add("**Full changelog:** https://github.com/$Repository/compare/v$PreviousVersion...v$Version")
    }

    $markdown = ''
    if ($sections.Count -gt 0) {
        $markdown = ($sections -join "`n`n") + "`n"
    }

    return [ordered]@{
        Markdown                 = $markdown
        BreakingText             = $breakingText
        LateBreakingPullRequests = [int[]]$late.ToArray()
    }
}
