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

$report = Join-Path $DiagnosticsPath 'csv-row-removals.json'
if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
    Write-AvmCatalogProgress 'No CSV row-removal report was produced, so nothing was held back.'
    return
}

$data = Read-AvmCatalogJson -Path $report
$held = @(if ($data.Contains('heldBackSourceFiles')) { $data.heldBackSourceFiles | ForEach-Object { [string]$_ } })
$removals = @(if ($data.Contains('removals')) { $data.removals })
if ($held.Count -eq 0) {
    Write-AvmCatalogProgress ('All catalog outputs were published and no source CSV rows would be lost ({0} removal(s) recorded).' -f $removals.Count)
    return
}

Write-AvmCatalogProgress ('Held back {0} output(s): {1}' -f $held.Count, ($held -join ', '))
foreach ($removal in $removals) {
    Write-AvmCatalogProgress ('  {0,-40} {1,-24} {2}' -f $removal.moduleName, $removal.reason, $removal.repoURL)
}

if ($SummaryPath) {
    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add('## Held-back catalog outputs')
    $summary.Add('')
    $summary.Add(('{0} source CSV row(s) have no matching module source, so these source CSVs and the catalog JSON were not published:' -f $removals.Count))
    $summary.Add('')
    foreach ($output in $held) {
        $summary.Add('- `' + $output + '`')
    }
    $summary.Add('')
    $summary.Add('| Source file | Module | Reason | Repository |')
    $summary.Add('| --- | --- | --- | --- |')
    foreach ($removal in $removals) {
        $summary.Add('| `' + [string]$removal.sourceFile + '` | `' + [string]$removal.moduleName + '` | ' +
            [string]$removal.reason + ' | ' + [string]$removal.repoURL + ' |')
    }
    Add-Content -LiteralPath $SummaryPath -Value ($summary -join "`n")
}

throw [System.IO.InvalidDataException]::new(
    ('{0} catalog output(s) were held back because source CSV rows would be removed. Fix the module sources, or re-run with force=true to accept the removals.' -f $held.Count))
