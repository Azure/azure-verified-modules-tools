# Shared fixture for the ModuleCatalog component test files; dot-source it from BeforeAll.
$repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
$catalogScripts = Join-Path $repoRoot 'repository-management' 'module-catalog' 'scripts'
Import-Module -Name (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
. (Join-Path $catalogScripts 'ModuleCatalog.ps1')
. (Join-Path $catalogScripts 'ModuleCatalog.Collection.ps1')
. (Join-Path $catalogScripts 'ModuleCatalog.Publication.ps1')
$inputSchema = Read-AvmCatalogJson -Path (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json')
$metadataSchemaId = $inputSchema['$id']

function Save-CatalogJson {
    param([string] $Path, [object] $Data)
    [System.IO.File]::WriteAllText($Path, (ConvertTo-AvmCatalogJson -Value $Data), [System.Text.UTF8Encoding]::new($false))
}

function Get-CatalogOwnerHandles {
    param([object[]] $Owners)
    return @($Owners | ForEach-Object { $_.handle })
}

function Save-CatalogMetadata {
    param([object] $Module, [switch] $Child)
    $marker = if ($Module.Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
    $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$Module.ModuleType]
    $data = [ordered]@{
        '$schema' = $metadataSchemaId
        moduleDisplayName = 'Authoritative module'
        moduleDescription = 'Deploys reviewed module.'
        canonicalType = $Module.Canonical
        telemetryIdPrefix = "$marker.$kind.test-module"
    }
    if (-not $Child) {
        $data.owners = @('owner-one', 'owner-two', 'owner-three', '@Azure/avm-core-modules')
        $data.alternativeNames = @('Alias one', 'Alias two')
        $data.comments = 'Reviewed comment.'
    }
    Save-CatalogJson -Path (Join-Path $Module.Directory 'metadata.json') -Data $data
}

function Add-CatalogModule {
    param(
        [object] $Fixture, [string] $Ecosystem, [string] $Repository,
        [string] $ModulePath, [string] $Canonical, [switch] $Child, [switch] $Adopt,
        [switch] $SourcePending
    )
    $identity = New-AvmCatalogIdentity -Ecosystem $Ecosystem -Repository $Repository -ModulePath $ModulePath
    $root = if ($Ecosystem -eq 'bicep') { $Fixture.Bicep } else { Join-Path $Fixture.Terraform $Repository.Substring('Azure/'.Length) }
    $directory = if ($ModulePath -eq '.') { $root } else { Join-Path $root $ModulePath }
    $null = [System.IO.Directory]::CreateDirectory($directory)
    $source = if ($Ecosystem -eq 'bicep') {
        "metadata name = 'Authoritative module'`nmetadata description = 'Deploys reviewed module.'`n"
    }
    else {
        "terraform {}`n"
    }
    $name = if ($Ecosystem -eq 'bicep') { 'main.bicep' } else { 'main.tf' }
    if (-not $SourcePending) {
        [System.IO.File]::WriteAllText((Join-Path $directory $name), $source)
    }
    $module = [pscustomobject]@{
        Ecosystem = $Ecosystem; Repository = $Repository; ModulePath = $ModulePath
        ModuleType = $identity.ModuleType; Canonical = $Canonical; Directory = $directory; Identity = $identity
    }
    $Fixture.Modules.Add($module)
    if ($Adopt) {
        Save-CatalogMetadata -Module $module -Child:$Child
    }
    return $module
}

function New-CatalogFixture {
    param([switch] $AdoptAll)
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $fixture = [pscustomobject]@{
        Root = $root; Legacy = Join-Path $root 'legacy'
        Bicep = Join-Path $root 'sources' 'bicep'; Terraform = Join-Path $root 'sources' 'terraform'
        Output = Join-Path $root 'generated'; Modules = [System.Collections.Generic.List[object]]::new()
        Original = @{}; Headers = @{}; Archived = @{}
    }
    foreach ($path in @($fixture.Legacy, $fixture.Bicep, $fixture.Terraform)) {
        $null = [System.IO.Directory]::CreateDirectory($path)
    }
    $outputs = @((Read-AvmCatalogConfiguration).outputs | Where-Object { $_.kind -ceq 'csv' })
    $bicepNames = @{
        resource = 'avm/res/storage/storage-account'
        pattern = 'avm/ptn/lz/sub-vending'
        utility = 'avm/utl/types/common'
    }
    $terraformNames = @{
        resource = 'avm-res-storage-storageaccount'
        pattern = 'avm-ptn-lz-sub-vending'
        utility = 'avm-utl-types-common'
    }
    $canonical = @{ resource = 'Microsoft.Storage/storageAccounts'; pattern = 'lz/sub-vending'; utility = 'types/common' }
    foreach ($output in $outputs) {
        $ecosystem = $output.ecosystem
        $kind = $output.moduleType
        $headers = @()
        if ($kind -eq 'resource') {
            $headers += @('ProviderNamespace', 'ResourceType')
        }
        $headers += @('ModuleDisplayName', 'AlternativeNames', 'ModuleName')
        if ($kind -eq 'resource') {
            $headers += 'ParentModule'
        }
        $headers += @('ModuleStatus', 'RepoURL', 'PublicRegistryReference')
        if ($ecosystem -eq 'bicep') {
            $headers += 'TelemetryIdPrefix'
        }
        $headers += @('PrimaryModuleOwnerGHHandle', 'PrimaryModuleOwnerDisplayName', 'SecondaryModuleOwnerGHHandle', 'SecondaryModuleOwnerDisplayName')
        if ($ecosystem -eq 'bicep') {
            $headers += 'ModuleOwnersGHTeam'
        }
        $headers += @('Description', 'Comments', 'FirstPublishedIn')
        $fixture.Headers[$output.sourceFile] = $headers
        $repository = if ($ecosystem -eq 'bicep') { 'Azure/bicep-registry-modules' } else { "Azure/terraform-azurerm-$($terraformNames[$kind])" }
        $modulePath = if ($ecosystem -eq 'bicep') { $bicepNames[$kind] } else { '.' }
        $module = Add-CatalogModule -Fixture $fixture -Ecosystem $ecosystem -Repository $repository `
            -ModulePath $modulePath -Canonical $canonical[$kind] -Adopt:$AdoptAll
        $values = @{
            ProviderNamespace = 'Microsoft.Storage'; ResourceType = 'storageAccounts'
            ModuleDisplayName = 'Legacy name'; AlternativeNames = 'Old alias, "quoted"'
            ModuleName = $module.Identity.ModuleName; ParentModule = 'n/a'
            ModuleStatus = 'Proposed'; RepoURL = $module.Identity.RepoURL; PublicRegistryReference = $module.Identity.Reference
            TelemetryIdPrefix = '46d3xbcp.res.old-prefix'; PrimaryModuleOwnerGHHandle = 'legacy-one'; PrimaryModuleOwnerDisplayName = 'Old One'
            SecondaryModuleOwnerGHHandle = 'legacy-two'; SecondaryModuleOwnerDisplayName = 'Old Two'; ModuleOwnersGHTeam = '@Azure/legacy-team'
            Description = "Old description, with a comma."; Comments = 'Keep exact legacy comment'; FirstPublishedIn = '2023-01'
        }
        $row = [ordered]@{}
        foreach ($header in $headers) {
            $row[$header] = $values[$header]
        }
        $fixture.Original[$output.sourceFile] = $row
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $output.sourceFile), (ConvertTo-AvmCatalogCsv -Headers $headers -Rows @($row)))
    }
    Save-CatalogJson -Path (Join-Path $fixture.Legacy 'BicepMARModules.json') -Data @($bicepNames.Values)
    return $fixture
}

function Get-CatalogFixtureInventory {
    param([object] $Fixture, [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration))
    Get-AvmCatalogInventory -BicepRoot $Fixture.Bicep -TerraformRoot $Fixture.Terraform -LegacyPath $Fixture.Legacy -Configuration $Configuration
}

function Get-CatalogFixtureBundle {
    [CmdletBinding()]
    param(
        [object] $Fixture, [object] $Inventory, [switch] $Force, [string] $DiagnosticsPath,
        [string[]] $MissingOwner = @(), [string[]] $Unpublished = @()
    )
    if ($null -eq $Inventory) {
        $Inventory = Get-CatalogFixtureInventory -Fixture $Fixture
    }
    $registry = [ordered]@{}
    foreach ($item in $Inventory.Items) {
        $published = -not $item.Identity.SourcePending -and $item.Identity.Key -cnotin $Unpublished
        $registry[$item.Identity.Key] = [ordered]@{
            status = if ($published) { 'available' } else { 'not-published' }
            currentVersion = if ($published) { '1.2.3' } else { $null }
            firstPublishedIn = if ($published) { '2024-02' } else { $null }
            downloads = if ($published -and $item.Identity.Ecosystem -eq 'terraform' -and $item.Identity.ModulePath -eq '.') { 123 } else { $null }
            marRegistered = if ($item.Identity.Ecosystem -eq 'bicep') { $true } else { $null }
        }
    }
    $revisions = @(
        foreach ($repository in @($Inventory.Items | Where-Object { $_.Identity.Ecosystem -eq 'terraform' } |
                ForEach-Object { $_.Identity.Repository } | Sort-Object -Unique)) {
            [ordered]@{
                repository = $repository
                commit = 'a' * 40
                status = 'collected'
                archived = if ($Fixture.Archived.ContainsKey($repository)) { $Fixture.Archived[$repository] } else { $false }
            }
        }
    )
    $github = [ordered]@{
        users = @{
            'owner-one' = @{ login = 'owner-one'; name = 'Profile One'; type = 'User' }
            'owner-two' = @{ login = 'owner-two'; name = 'Profile Two'; type = 'User' }
            'owner-three' = @{ login = 'owner-three'; name = $null; type = 'User' }
        }
        teams = @{
            '@Azure/avm-core-modules' = @{
                slug = 'avm-core-modules'; organization = 'Azure'; description = 'Maintains AVM core modules.'
            }
            '@Azure/second-team' = @{ slug = 'second-team'; organization = 'Azure'; description = $null }
        }
    }
    foreach ($handle in $MissingOwner) {
        if ($handle.StartsWith('@')) {
            $github.teams[$handle] = $null
        } else {
            $github.users[$handle] = $null
        }
    }
    Save-CatalogJson -Path (Join-Path $Fixture.Root 'registry.json') -Data $registry
    Save-CatalogJson -Path (Join-Path $Fixture.Root 'github.json') -Data $github
    Save-CatalogJson -Path (Join-Path $Fixture.Root 'revisions.json') -Data $revisions
    return New-AvmCatalogBundle -Inventory $Inventory -Registry $registry -GitHub $github -RepositoryRevisions $revisions -Force:$Force -DiagnosticsPath $DiagnosticsPath
}

function Initialize-CatalogPublicationBase {
    param([object] $Fixture)

    $configuration = Read-AvmCatalogConfiguration
    $sourceRoot = Join-Path $Fixture.Root 'publication-base'
    foreach ($output in $configuration.outputs | Where-Object { $_.kind -in @('csv', 'mar') }) {
        $file = if ($output.kind -eq 'csv') { $output.sourceFile } else { $output.file }
        $target = Join-Path $sourceRoot $output.targetPath
        $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath (Join-Path $Fixture.Legacy $file) -Destination $target
    }
    $plan = Copy-AvmCatalogInputFile -Configuration $configuration -RepositoryRoots @{ docs = $sourceRoot } `
        -SnapshotPath (Join-Path $Fixture.Root 'publication-input') -Confirm:$false
    Save-CatalogJson -Path (Join-Path $Fixture.Root 'publication.json') -Data $plan
    return $sourceRoot
}
