#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DiagnosticsPath,
    [string] $SummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsRoot = Join-Path $PSScriptRoot '..' '..' '..'
Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')

$removals = @()
$held = [System.Collections.Generic.List[string]]::new()
$report = Join-Path $DiagnosticsPath 'csv-row-removals.json'
if (Test-Path -LiteralPath $report -PathType Leaf) {
    $data = Read-AvmCatalogJson -Path $report
    $removals = @(if ($data.Contains('removals')) { $data.removals })
    foreach ($file in @(if ($data.Contains('heldBackSourceFiles')) { $data.heldBackSourceFiles })) {
        $held.Add([string]$file)
    }
}

$owners = @()
$ownerReport = Join-Path $DiagnosticsPath 'missing-owners.json'
if (Test-Path -LiteralPath $ownerReport -PathType Leaf) {
    $ownerData = Read-AvmCatalogJson -Path $ownerReport
    if (-not $ownerData.missingOwnersForced) {
        $owners = @(if ($ownerData.Contains('missingOwners')) { $ownerData.missingOwners })
        foreach ($defect in $owners) {
            if ([string]$defect.sourceFile -cnotin $held) {
                $held.Add([string]$defect.sourceFile)
            }
        }
    }
}

if ($held.Count -eq 0) {
    Write-AvmCatalogProgress ('All catalog outputs were published: {0} row removal(s) and 0 missing owner(s) recorded.' -f $removals.Count)
    return
}

Write-AvmCatalogProgress ('Held back {0} source CSV file(s): {1}' -f $held.Count, ($held -join ', '))
foreach ($removal in $removals) {
    Write-AvmCatalogProgress ('  row removed  {0,-40} {1,-24} {2}' -f $removal.moduleName, $removal.reason, $removal.repoURL)
}
foreach ($defect in $owners) {
    Write-AvmCatalogProgress ('  owner gone   {0,-40} {1}' -f $defect.moduleName, (@($defect.owners) -join ', '))
}

if ($SummaryPath) {
    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add('## Held-back catalog outputs')
    $summary.Add('')
    $summary.Add(('These source CSVs and the catalog JSON were not published: {0} row(s) have no matching module source and {1} module(s) name a GitHub owner that no longer exists.' -f $removals.Count, $owners.Count))
    $summary.Add('')
    foreach ($output in $held) {
        $summary.Add('- `' + $output + '`')
    }
    if ($removals.Count -gt 0) {
        $summary.Add('')
        $summary.Add('### Rows that would be removed')
        $summary.Add('')
        $summary.Add('| Source file | Module | Reason | Repository |')
        $summary.Add('| --- | --- | --- | --- |')
        foreach ($removal in $removals) {
            $summary.Add('| `' + [string]$removal.sourceFile + '` | `' + [string]$removal.moduleName + '` | ' +
                [string]$removal.reason + ' | ' + [string]$removal.repoURL + ' |')
        }
    }
    if ($owners.Count -gt 0) {
        $summary.Add('')
        $summary.Add('### Modules whose GitHub owner no longer exists')
        $summary.Add('')
        $summary.Add('| Source file | Module | Missing owner(s) | Repository |')
        $summary.Add('| --- | --- | --- | --- |')
        foreach ($defect in $owners) {
            $summary.Add('| `' + [string]$defect.sourceFile + '` | `' + [string]$defect.moduleName + '` | ' +
                (@($defect.owners) -join ', ') + ' | ' + [string]$defect.repoURL + ' |')
        }
    }
    Add-Content -LiteralPath $SummaryPath -Value ($summary -join "`n")
}

throw [System.IO.InvalidDataException]::new(
    ('{0} source CSV file(s) were held back: {1} row(s) would be removed and {2} module(s) name a GitHub owner that no longer exists. Fix the module sources or owners, or re-run with force=true to accept them.' -f $held.Count, $removals.Count, $owners.Count))