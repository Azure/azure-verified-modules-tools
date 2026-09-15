#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $DocumentationRoot,
    [Parameter(Mandatory)][string] $BicepRoot,
    [Parameter(Mandatory)][string] $SnapshotPath,
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..' 'config.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')
. (Join-Path $PSScriptRoot 'ModuleCatalog.Collection.ps1')

$configuration = Read-AvmCatalogConfiguration -Path $ConfigurationPath
if (-not $env:GH_TOKEN) {
    throw [System.InvalidOperationException]::new('GH_TOKEN is required for read-only GitHub collection and owner/team validation.')
}
$token = ConvertTo-SecureString -String $env:GH_TOKEN -AsPlainText -Force
$destination = [System.IO.Path]::GetFullPath($SnapshotPath)
if (Test-Path -LiteralPath $destination) {
    throw [System.IO.IOException]::new('SnapshotPath must be a new directory.')
}
if (-not $PSCmdlet.ShouldProcess($destination, 'Collect a read-only module catalog snapshot')) {
    return
}
$parent = [System.IO.Path]::GetDirectoryName($destination)
$null = [System.IO.Directory]::CreateDirectory($parent)
$staging = Join-Path $parent ('.catalog-input-' + [guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($staging)
try {
    $legacy = Join-Path $staging 'legacy'
    $bicep = Join-Path $staging 'sources' 'bicep'
    $terraform = Join-Path $staging 'sources' 'terraform'
    foreach ($directory in @($legacy, $bicep, $terraform)) {
        $null = [System.IO.Directory]::CreateDirectory($directory)
    }
    $roots = @{ docs = $DocumentationRoot; tools = $toolsRoot }
    $publication = Copy-AvmCatalogInputFile -Configuration $configuration -RepositoryRoots $roots -SnapshotPath $staging -Confirm:$false

    $bicepSources = Get-AvmCatalogSources -BicepRoot $BicepRoot -TerraformRoot $terraform -Configuration $configuration
    foreach ($source in $bicepSources) {
        $directory = Join-Path $bicep $source.ModulePath
        $null = [System.IO.Directory]::CreateDirectory($directory)
        foreach ($file in @(Get-ChildItem -LiteralPath $source.Directory -File | Where-Object { $_.Name -in @('main.bicep', 'metadata.json', 'version.json') })) {
            [System.IO.File]::Copy($file.FullName, (Join-Path $directory $file.Name))
        }
    }
    $revisions = [System.Collections.Generic.List[object]]::new()
    $git = (Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    foreach ($inputRepository in @(
            @{ Name = $configuration.repositories.docs; Path = $DocumentationRoot },
            @{ Name = $configuration.repositories.bicep; Path = $BicepRoot },
            @{ Name = $configuration.repositories.tools; Path = $toolsRoot }
        )) {
        $revision = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('rev-parse', 'HEAD') -WorkingDirectory $inputRepository.Path
        $revisions.Add([ordered]@{ repository = $inputRepository.Name; commit = $revision.StdOut.Trim(); status = 'collected' })
    }
    $repositories = Get-AvmCatalogTerraformRepositories -GitHubToken $token -LegacyPath $legacy -Configuration $configuration
    foreach ($repository in $repositories) {
        $directory = Join-Path $terraform $repository.Substring('Azure/'.Length)
        $result = Save-AvmCatalogTerraformSource -Repository $repository -Destination $directory -GitHubToken $token -Confirm:$false
        $revisions.Add($result)
    }
    $inventory = Get-AvmCatalogInventory -BicepRoot $bicep -TerraformRoot $terraform -LegacyPath $legacy -Configuration $configuration
    $enrichment = Get-AvmCatalogEnrichment -Inventory $inventory -GitHubToken $token
    foreach ($file in @(
            @{ Name = 'github.json'; Value = $enrichment.GitHub },
            @{ Name = 'registry.json'; Value = $enrichment.Registry },
            @{ Name = 'publication.json'; Value = $publication },
            @{ Name = 'revisions.json'; Value = $revisions.ToArray() }
        )) {
        [System.IO.File]::WriteAllText((Join-Path $staging $file.Name), (ConvertTo-AvmCatalogJson -Value $file.Value), [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.Directory]::Move($staging, $destination)
}
finally {
    $token.Dispose()
    if ([System.IO.Directory]::Exists($staging)) {
        [System.IO.Directory]::Delete($staging, $true)
    }
}
Write-Output $destination
