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
    [switch] $AllowMissing
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

$sectionText
