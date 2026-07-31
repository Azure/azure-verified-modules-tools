[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Version,

    [Parameter(Position = 1)]
    [string] $ChangelogPath = (Join-Path $PSScriptRoot '..' 'CHANGELOG.md'),

    # Return nothing instead of throwing when the version has no section (or an
    # empty one). The release workflow treats a CHANGELOG entry as a bonus, not
    # a gate: releases are cut from the GitHub UI, where the release body has
    # usually already been authored or auto-generated.
    [Parameter()]
    [switch] $AllowMissing,

    # Cap the returned text, truncating on a line boundary and appending a link
    # to the full notes. 0 (the default) means unlimited.
    #
    # The PowerShell Gallery rejects the whole package when the manifest's
    # ReleaseNotes exceeds 10600 characters, and it does so at publish time --
    # after the tag and the GitHub Release already exist. v0.1.7 was rejected at
    # 23987. Only the manifest-stamping path needs a cap; the GitHub Release body
    # has no such limit and takes the full section.
    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $MaxLength = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ChangelogPath)) {
    if ($AllowMissing) {
        Write-Verbose "CHANGELOG not found at $ChangelogPath; returning nothing."
        return
    }
    throw "CHANGELOG not found at $ChangelogPath."
}

$content = Get-Content -LiteralPath $ChangelogPath -Raw
$lines   = $content -split "`r?`n"

# Anchor on `## [<version>]` so we never accidentally match a similarly-named
# version (e.g. asking for `0.1.0` and matching `0.1.0-preview.1`).
$wantedHeader = '## [{0}]' -f $Version
$start = -1
$end   = $lines.Count

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($start -lt 0) {
        if ($lines[$i] -eq $wantedHeader -or $lines[$i].StartsWith("$wantedHeader ")) {
            $start = $i + 1
        }
        continue
    }
    if ($lines[$i] -match '^## \[') {
        $end = $i
        break
    }
}

if ($start -lt 0) {
    if ($AllowMissing) {
        Write-Verbose "No CHANGELOG section for version '$Version'; returning nothing."
        return
    }
    throw "No CHANGELOG section found for version '$Version' in $ChangelogPath. Add a '## [$Version] - YYYY-MM-DD' heading before tagging."
}

$sectionLines = if ($end -gt $start) { @($lines[$start..($end - 1)]) } else { @() }
$sectionText  = ($sectionLines -join "`n").Trim()

if ([string]::IsNullOrWhiteSpace($sectionText)) {
    if ($AllowMissing) {
        Write-Verbose "CHANGELOG section for version '$Version' is empty; returning nothing."
        return
    }
    throw "CHANGELOG section for version '$Version' is empty in $ChangelogPath. Add release notes before tagging."
}

if ($MaxLength -gt 0) {
    # NuGet may rewrite LF as CRLF when it lifts the value out of the manifest,
    # so budget for the worst case rather than the length visible here.
    $measure = { param([string] $Text) $Text.Length + ([regex]::Matches($Text, "`n")).Count }

    if ((& $measure $sectionText) -gt $MaxLength) {
        $footer = "`n`n---`n`nThese notes are truncated to fit the PowerShell Gallery's $MaxLength-character limit. " +
                  "Full notes: https://github.com/Azure/azure-verified-modules-tools/releases/tag/v$Version"

        $budget = $MaxLength - (& $measure $footer)
        if ($budget -le 0) {
            throw "MaxLength $MaxLength is too small to hold the truncation footer on its own."
        }

        # Truncate from the bottom, on a line boundary. A CHANGELOG section
        # leads with its most consequential content -- `### Breaking` is first
        # by convention -- so the tail is the safe end to lose.
        $kept = @()
        foreach ($line in ($sectionText -split "`n")) {
            if ((& $measure (($kept + $line) -join "`n")) -gt $budget) { break }
            $kept += $line
        }
        if ($kept.Count -eq 0) {
            throw "MaxLength $MaxLength cannot hold even the first line of the '$Version' section."
        }

        $sectionText = ($kept -join "`n").TrimEnd() + $footer

        # Verify the arithmetic instead of trusting it. Getting this wrong stays
        # invisible until the gallery rejects the package mid-release, by which
        # point the tag and the GitHub Release already exist.
        $finalLength = & $measure $sectionText
        if ($finalLength -gt $MaxLength) {
            throw "Truncation produced $finalLength characters, which still exceeds MaxLength $MaxLength."
        }
        Write-Verbose "Truncated the '$Version' notes to $finalLength characters (limit $MaxLength)."
    }
}

$sectionText
