<#
.SYNOPSIS
    Appends one dated summary row to the release-status history.

.DESCRIPTION
    The per-module snapshot in release-status.json is rebuilt from the GitHub API on
    every run, so it can always be recomputed and is never committed. History cannot.
    Once a day passes, the counts for that day are unrecoverable, because the API only
    reports the present. This file is therefore the one piece of generated data that
    belongs in version control.

    Re-running on a date that already has a row replaces it, so a manual run does not
    create a duplicate for the same day.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$StatusPath = "$PSScriptRoot/../site/data/release-status.json",
    [string]$HistoryPath = "$PSScriptRoot/../site/data/history.json",
    [int]$AgedDays = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $StatusPath)) { throw "No status file at $StatusPath" }
$status = Get-Content $StatusPath -Raw | ConvertFrom-Json
$modules = @($status.modules)

# Recorded but not charted. The dashboard dropped this series because it barely
# moves, but a past day cannot be recomputed, so dropping the field would make the
# metric unrecoverable rather than merely hidden.
$aged = @($modules | Where-Object {
        $_.state -eq 'unreleased-work' -and $null -ne $_.oldestHumanDays -and $_.oldestHumanDays -gt $AgedDays
    })

$entry = [ordered]@{
    date              = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    repoCount         = $modules.Count
    unreleasedWork    = @($modules | Where-Object state -EQ 'unreleased-work').Count
    aged              = $aged.Count
    neverReleased     = @($modules | Where-Object state -EQ 'never-released').Count
    nothingToRelease  = @($modules | Where-Object { $_.state -in @('automation-only', 'current') }).Count
    unreleasedPrs     = [int](@($modules | ForEach-Object { @($_.unreleasedPrs).Count } | Measure-Object -Sum).Sum)
    awaitingIssues    = [int](@($modules | ForEach-Object { @($_.awaitingReleaseIssues).Count } | Measure-Object -Sum).Sum)
}

$history = @()
if (Test-Path $HistoryPath) {
    $existing = Get-Content $HistoryPath -Raw
    if ($existing.Trim()) { $history = @(($existing | ConvertFrom-Json)) }
}

$history = @($history | Where-Object { $_.date -ne $entry.date })
$history += [pscustomobject]$entry
$history = @($history | Sort-Object date)

if ($PSCmdlet.ShouldProcess($HistoryPath, "Write $($history.Count) rows")) {
    $directory = Split-Path -Parent $HistoryPath
    if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [IO.File]::WriteAllText($HistoryPath, ($history | ConvertTo-Json -Depth 4 -AsArray), [Text.UTF8Encoding]::new($false))
    Write-Host "History now has $($history.Count) rows, newest $($entry.date)"
}
