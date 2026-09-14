#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $InputPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [ValidateSet('dual-source', 'metadata-only')][string] $BicepMode = 'dual-source',
    [ValidateSet('dual-source', 'metadata-only')][string] $TerraformMode = 'dual-source'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsRoot = Join-Path $PSScriptRoot '..' '..' '..'
Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')

$inventory = Get-AvmCatalogInventory -BicepRoot (Join-Path $InputPath 'sources' 'bicep') `
    -TerraformRoot (Join-Path $InputPath 'sources' 'terraform') -LegacyPath (Join-Path $InputPath 'legacy') `
    -BicepMode $BicepMode -TerraformMode $TerraformMode
$bundle = New-AvmCatalogBundle -Inventory $inventory `
    -Registry (Read-AvmCatalogJson -Path (Join-Path $InputPath 'registry.json')) `
    -GitHub (Read-AvmCatalogJson -Path (Join-Path $InputPath 'github.json')) `
    -RepositoryConfiguration (Read-AvmCatalogJson -Path (Join-Path $InputPath 'repository-config.json'))

$publicationPath = Join-Path $InputPath 'publication.json'
if (Test-Path -LiteralPath $publicationPath -PathType Leaf) {
    $plan = Read-AvmCatalogJson -Path $publicationPath
    $plan['outputHashes'] = [ordered]@{}
    foreach ($relative in $bundle.Files.Keys) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bundle.Files[$relative])
        $plan.outputHashes[$relative] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    $bundle.Files['plan.json'] = ConvertTo-AvmCatalogJson -Value $plan
}
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the validated dual-source catalog and migration report')) {
    Write-AvmCatalogBundle -Bundle $bundle -OutputPath $OutputPath -Confirm:$false
}
