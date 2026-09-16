#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $InputPath,
    [Parameter(Mandatory)][string] $OutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
if (-not $PSCmdlet.ShouldProcess($InputPath, 'Prepare module metadata and write the worker result')) {
    return
}
$authoring = Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -PassThru -ErrorAction Stop
$inputData = & $authoring {
    param($Path)
    ConvertFrom-AvmMetadataJson -Json (Get-Content -LiteralPath $Path -Raw)
} $InputPath
$preparationErrors = @()
$results = @(& (Join-Path $PSScriptRoot 'Invoke-ModuleMetadataBackfill.ps1') `
        -RepositoryRoot $inputData.RepositoryRoot -Repository $inputData.Repository -Ecosystem terraform `
        -LegacyRecord $inputData.LegacyRecord -Confirm:$false -ErrorVariable preparationErrors)
if ($preparationErrors.Count -gt 0) {
    throw [System.InvalidOperationException]::new("Metadata preparation failed: $($preparationErrors -join '; ')")
}
if ($results.Count -ne 1 -or -not $results[0].PSObject.Properties['Status'] -or $results[0].Status -cne 'pass') {
    throw [System.InvalidOperationException]::new('Metadata preparation did not return one successful result.')
}
[System.IO.File]::WriteAllText($OutputPath, (ConvertTo-Json -InputObject $results[0] -Depth 64), [System.Text.UTF8Encoding]::new($false))
