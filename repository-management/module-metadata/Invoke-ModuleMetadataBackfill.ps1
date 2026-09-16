<#
.SYNOPSIS
    Create missing metadata.json files from existing indexes and module source.
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
    [string[]] $LegacyCsvPath = @(),
    [object[]] $LegacyRecord = @(),
    [switch] $UpdateSource
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'MetadataBackfill.ps1')
if (-not (Get-Module -Name Avm.Authoring)) {
    Import-Module Avm.Authoring -ErrorAction Stop
}
Assert-AvmMetadataBackfillCapability
$root = Resolve-AvmMetadataBackfillRoot -Path $RepositoryRoot
$records = [System.Collections.Generic.List[object]]::new()
foreach ($record in $LegacyRecord) { $records.Add($record) }
foreach ($csv in $LegacyCsvPath) {
    foreach ($row in Import-Csv -LiteralPath $csv) {
        $record = @{}
        foreach ($property in $row.PSObject.Properties) { $record[$property.Name] = $property.Value }
        $records.Add($record)
    }
}
$plans = @(Get-AvmMetadataBackfillPlan -Root $root -Repository $Repository -Ecosystem $Ecosystem `
        -LegacyRecord $records.ToArray() -UpdateSource:$UpdateSource)
$results = [System.Collections.Generic.List[object]]::new()
$apply = $PSCmdlet.ShouldProcess($root, "Create missing metadata.json files for $($plans.Count) modules")
if ($apply) {
    $null = Get-AvmMetadataBackfillModule -Root $root -Ecosystem $Ecosystem -Repository $Repository
}
foreach ($plan in $plans) {
    $changed = $false
    if ($apply) {
        $null = Resolve-AvmMetadataBackfillPath -Root $root -RelativePath $plan.Path
        $parameters = $plan.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -Path $plan.FullPath -InputObject $plan.Metadata `
            -UpdateSource:$plan.UpdateSource -Confirm:$false
        if ($result.Status -ne 'pass') {
            throw [System.InvalidOperationException]::new("Initialization failed for '$($plan.Path)': $($result.Status)")
        }
        $changed = $result.Changed
    }
    $results.Add([pscustomobject]@{
            Path         = $plan.Path
            Status       = if ($apply) { 'pass' } else { 'planned' }
            Changed      = $changed
            UpdateSource = $plan.UpdateSource
            PlannedFiles = $plan.PlannedFiles
        })
}
[pscustomobject]@{
    Status     = if ($apply) { 'pass' } else { 'planned' }
    Repository = $Repository
    Changed    = @($results | Where-Object { $_.Changed }).Count -gt 0
    Modules    = $results.ToArray()
}
