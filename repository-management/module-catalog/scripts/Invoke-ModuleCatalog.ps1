#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $InputPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [ValidateSet('dual-source', 'metadata-only')][string] $BicepMode = 'dual-source',
    [ValidateSet('dual-source', 'metadata-only')][string] $TerraformMode = 'dual-source',
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..' 'config.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsRoot = Join-Path $PSScriptRoot '..' '..' '..'
Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')

$configuration = Read-AvmCatalogConfiguration -Path $ConfigurationPath
$inventory = Get-AvmCatalogInventory -BicepRoot (Join-Path $InputPath 'sources' 'bicep') `
    -TerraformRoot (Join-Path $InputPath 'sources' 'terraform') -LegacyPath (Join-Path $InputPath 'legacy') `
    -BicepMode $BicepMode -TerraformMode $TerraformMode -Configuration $configuration
$bundle = New-AvmCatalogBundle -Inventory $inventory `
    -Registry (Read-AvmCatalogJson -Path (Join-Path $InputPath 'registry.json')) `
    -GitHub (Read-AvmCatalogJson -Path (Join-Path $InputPath 'github.json')) `
    -RepositoryConfiguration (Read-AvmCatalogJson -Path (Join-Path $InputPath 'repository-config.json'))

$publicationPath = Join-Path $InputPath 'publication.json'
if (Test-Path -LiteralPath $publicationPath -PathType Leaf) {
    $plan = Read-AvmCatalogJson -Path $publicationPath
    if ($plan['manifestHash'] -cne $configuration.hash) {
        throw [System.IO.InvalidDataException]::new('The catalog manifest changed after collection. Collect a new snapshot.')
    }
    $plan['outputHashes'] = [ordered]@{}
    foreach ($relative in $bundle.Files.Keys) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bundle.Files[$relative])
        $plan.outputHashes[$relative] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    $planOutput = Get-AvmCatalogOutput -Configuration $configuration -Kind publication-plan
    $bundle.Files[$planOutput.bundlePath] = ConvertTo-AvmCatalogJson -Value $plan
}
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the validated dual-source catalog and migration report')) {
    Write-AvmCatalogBundle -Bundle $bundle -OutputPath $OutputPath -Configuration $configuration -Confirm:$false
}
