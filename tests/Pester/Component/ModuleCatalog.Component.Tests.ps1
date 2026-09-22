#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
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
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: module catalog helpers' -Tag Component {
    It 'retains mixed helper inventories in JSON but not any <Destination> CSV' -TestCases @(
        @{ Destination = 'preview' }
        @{ Destination = 'canonical' }
    ) {
        param($Destination)
        $fixture = New-CatalogFixture -AdoptAll
        $helpers = [System.Collections.Generic.List[object]]::new()
        foreach ($family in @($fixture.Modules)) {
            $normalPath = if ($family.Ecosystem -eq 'bicep') { "$($family.ModulePath)/normal" } else { 'modules/normal' }
            $null = Add-CatalogModule -Fixture $fixture -Ecosystem $family.Ecosystem -Repository $family.Repository `
                -ModulePath $normalPath -Canonical $family.Canonical -Child -Adopt
            $parent = $family.ModulePath
            foreach ($name in @('helper-a', 'helper-b')) {
                $path = if ($family.Ecosystem -eq 'bicep') { "$parent/$name" } else { "modules/$name" }
                $helper = Add-CatalogModule -Fixture $fixture -Ecosystem $family.Ecosystem -Repository $family.Repository `
                    -ModulePath $path -Canonical 'helper' -Child -Adopt
                $metadataPath = Join-Path $helper.Directory 'metadata.json'
                $metadata = Read-AvmCatalogJson -Path $metadataPath
                if ($name -eq 'helper-a') {
                    $metadata.Remove('telemetryIdPrefix')
                    Save-CatalogJson -Path $metadataPath -Data $metadata
                }
                $helpers.Add(@{ Module = $helper; Family = $family; Parent = $parent; Metadata = $metadata })
                if ($family.Ecosystem -eq 'bicep') { $parent = $path }
            }
        }
        $raw = Read-AvmCatalogJson -Path (Join-Path $catalogScripts '..' 'config.json')
        if ($Destination -eq 'preview') {
            foreach ($csv in $raw.outputs | Where-Object kind -eq 'csv') { $csv.file = "test-$($csv.sourceFile)" }
        }
        $configurationPath = Join-Path $fixture.Root 'catalog-manifest.json'
        Save-CatalogJson -Path $configurationPath -Data $raw
        $configuration = Read-AvmCatalogConfiguration -Path $configurationPath
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture -Configuration $configuration
        $inventory.Sources | Should -HaveCount 24
        $inventory.Items | Should -HaveCount 24
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory
        $catalog = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
        $catalog.modules.helper.bicep | Should -HaveCount 6
        $catalog.modules.helper.terraform | Should -HaveCount 6
        foreach ($helper in $helpers) {
            $module = $helper.Module
            $records = @($catalog.modules.helper[$module.Ecosystem] | Where-Object {
                    $_.repository -ceq $module.Repository -and $_.modulePath -ceq $module.ModulePath
                })
            $records | Should -HaveCount 1
            $record = $records[0]
            $record.canonicalType | Should -BeExactly 'helper'
            $record.moduleName | Should -BeExactly $module.Identity.ModuleName
            $record.moduleType | Should -BeExactly $helper.Family.ModuleType
            $record.parentModule | Should -BeExactly $helper.Parent
            $record.familyModule | Should -BeExactly $helper.Family.ModulePath
            Get-CatalogOwnerHandles $record.owners | Should -Be @('owner-one', 'owner-two', 'owner-three', '@Azure/avm-core-modules')
            $record.provider | Should -Be $module.Identity.Provider
            $record.Contains('providerNamespace') | Should -BeTrue
            $record.Contains('resourceType') | Should -BeTrue
            ($null -eq $record.providerNamespace) | Should -BeTrue
            ($null -eq $record.resourceType) | Should -BeTrue
            $record.telemetryIdPrefix | Should -Be $helper.Metadata['telemetryIdPrefix']
        }
        foreach ($output in $configuration.outputs | Where-Object kind -eq 'csv') {
            $rows = @($bundle.Files[$output.bundlePath] | ConvertFrom-Csv)
            # Terraform submodule rows are excluded from the CSV, so only root modules are expected there.
            $expected = @($inventory.Items | Where-Object {
                    $_.Record.ecosystem -eq $output.ecosystem -and $_.Record.moduleType -eq $output.moduleType -and
                    $_.Record.canonicalType -cne 'helper' -and
                    -not ($_.Record.ecosystem -eq 'terraform' -and $_.Record.modulePath -cne '.')
                } | ForEach-Object { $_.Record.moduleName } | Sort-Object)
            $rows | Should -HaveCount $expected.Count
            @($rows.ModuleName | Sort-Object) | Should -Be $expected
        }
        $bundle.Report.counts.catalogEntries | Should -Be 24
        $bundle.Report.missingMetadata | Should -HaveCount 0
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
        $again = Get-CatalogFixtureBundle -Fixture $fixture `
            -Inventory (Get-CatalogFixtureInventory -Fixture $fixture -Configuration $configuration)
        foreach ($file in $bundle.Files.Keys) {
            $again.Files[$file] | Should -BeExactly $bundle.Files[$file]
        }
    }

    It 'rejects authored helpers at <Ecosystem> <ModuleType> family roots even with force' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('resource', 'pattern', 'utility')) {
                @{ Ecosystem = $ecosystem; ModuleType = $kind }
            }
        }
    ) {
        param($Ecosystem, $ModuleType)
        $fixture = New-CatalogFixture -AdoptAll
        $family = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq $ModuleType })[0]
        $path = Join-Path $family.Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $path
        $metadata.canonicalType = 'helper'
        Save-CatalogJson -Path $path -Data $metadata
        foreach ($force in @($false, $true)) {
            { Get-CatalogFixtureBundle -Fixture $fixture -Force:$force } | Should -Throw '*Invalid present metadata*'
        }
    }

    It 'rejects invalid helper catalog shapes for <Ecosystem> <ModuleType>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('resource', 'pattern', 'utility')) {
                @{ Ecosystem = $ecosystem; ModuleType = $kind }
            }
        }
    ) {
        param($Ecosystem, $ModuleType)
        $fixture = New-CatalogFixture -AdoptAll
        $family = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq $ModuleType })[0]
        $path = if ($Ecosystem -eq 'bicep') { "$($family.ModulePath)/helper" } else { 'modules/helper' }
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem $Ecosystem -Repository $family.Repository `
            -ModulePath $path -Canonical 'helper' -Child -Adopt
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $schema = Join-Path $repoRoot (Get-AvmCatalogOutput -Configuration $bundle.Configuration -Kind catalog).schema
        $json = $bundle.Files['docs/v1/modules.json']
        Test-Json -Json $json -SchemaFile $schema | Should -BeTrue
        foreach ($mutation in @(
                @{ Property = 'parentModule'; Value = $null },
                @{ Property = 'parentModule'; Value = '' },
                @{ Property = 'modulePath'; Value = $family.ModulePath },
                @{ Property = 'providerNamespace'; Value = 'helper' },
                @{ Property = 'resourceType'; Value = 'helper' },
                @{ Property = 'canonicalType'; Value = 'Helper' },
                @{ Property = 'moduleType'; Value = 'helper' }
            )) {
            $catalog = $json | ConvertFrom-Json -AsHashtable
            $catalog.modules.helper[$Ecosystem][0][$mutation.Property] = $mutation.Value
            Test-Json -Json (ConvertTo-AvmCatalogJson -Value $catalog) -SchemaFile $schema `
                -ErrorAction SilentlyContinue | Should -BeFalse
        }
        foreach ($field in @('providerNamespace', 'resourceType')) {
            $catalog = $json | ConvertFrom-Json -AsHashtable
            $catalog.modules['Microsoft.Storage/storageAccounts'][$Ecosystem][0][$field] = $null
            Test-Json -Json (ConvertTo-AvmCatalogJson -Value $catalog) -SchemaFile $schema `
                -ErrorAction SilentlyContinue | Should -BeFalse
        }
        foreach ($mutation in @(
                @{ Property = 'type'; Value = 'team' },
                @{ Property = 'handle'; Value = '@Azure/avm-core-modules' },
                @{ Property = 'displayName'; Value = 42 },
                @{ Property = 'extra'; Value = 'unsupported' }
            )) {
            $catalog = $json | ConvertFrom-Json -AsHashtable
            $owner = $catalog.modules.helper[$Ecosystem][0].owners[0]
            $owner[$mutation.Property] = $mutation.Value
            Test-Json -Json (ConvertTo-AvmCatalogJson -Value $catalog) -SchemaFile $schema `
                -ErrorAction SilentlyContinue | Should -BeFalse
        }
        foreach ($property in @('handle', 'type', 'displayName')) {
            $catalog = $json | ConvertFrom-Json -AsHashtable
            $catalog.modules.helper[$Ecosystem][0].owners[0].Remove($property)
            Test-Json -Json (ConvertTo-AvmCatalogJson -Value $catalog) -SchemaFile $schema `
                -ErrorAction SilentlyContinue | Should -BeFalse
        }
    }

    It 'keeps helper source-row removal guards through <Destination> generation and publication' -TestCases @(
        @{ Destination = 'preview' }
        @{ Destination = 'canonical' }
    ) {
        param($Destination)
        $fixture = New-CatalogFixture -AdoptAll
        $raw = Read-AvmCatalogJson -Path (Join-Path $catalogScripts '..' 'config.json')
        if ($Destination -eq 'preview') {
            foreach ($csv in $raw.outputs | Where-Object kind -eq 'csv') { $csv.file = "test-$($csv.sourceFile)" }
        }
        $configurationPath = Join-Path $fixture.Root 'catalog-manifest.json'
        Save-CatalogJson -Path $configurationPath -Data $raw
        $configuration = Read-AvmCatalogConfiguration -Path $configurationPath
        foreach ($family in @($fixture.Modules)) {
            $path = if ($family.Ecosystem -eq 'bicep') { "$($family.ModulePath)/helper" } else { 'modules/helper' }
            $helper = Add-CatalogModule -Fixture $fixture -Ecosystem $family.Ecosystem -Repository $family.Repository `
                -ModulePath $path -Canonical 'helper' -Child -Adopt
            $output = @($configuration.outputs | Where-Object {
                    $_.kind -eq 'csv' -and $_.ecosystem -eq $family.Ecosystem -and $_.moduleType -eq $family.ModuleType
                })[0]
            $file = $output.sourceFile
            $row = [ordered]@{}
            foreach ($header in $fixture.Headers[$file]) { $row[$header] = $fixture.Original[$file][$header] }
            $row.ModuleName = $helper.Identity.ModuleName
            $row.RepoURL = $helper.Identity.RepoURL
            $row.ModuleStatus = 'Deprecated'
            [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
                (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $row)))
            [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy "test-$file"), 'Preview rows must not be read as source.')
        }
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture -Configuration $configuration
        $held = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory
        $held.HeldBackSourceFiles | Should -HaveCount 6
        $held.HeldBack | Should -Contain 'docs/v1/modules.json'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory -Force
        $bundle.Report.counts.catalogEntries | Should -Be 12
        $bundle.Report.csvRowRemovals | Should -HaveCount 6
        $bundle.Report.csvRowRemovalsForced | Should -BeTrue
        $bundle.Report.missingMetadata | Should -HaveCount 0
        foreach ($ecosystem in @('bicep', 'terraform')) {
            $records = $bundle.Catalog.modules.helper[$ecosystem]
            $records | Should -HaveCount 3
            foreach ($record in $records) { $record.moduleStatus | Should -BeExactly 'Deprecated' }
        }
        $sourceRoot = Join-Path $fixture.Root 'publication-source'
        foreach ($output in $configuration.outputs | Where-Object kind -eq 'csv') {
            $rows = @($bundle.Files[$output.bundlePath] | ConvertFrom-Csv)
            $rows | Should -HaveCount 1
            $rows[0].ModuleName | Should -BeExactly $fixture.Original[$output.sourceFile].ModuleName
            $bundle.Report.sourceCsvRows[$output.sourceFile] | Should -HaveCount 2
            $removals = @($bundle.Report.csvRowRemovals | Where-Object sourceFile -eq $output.sourceFile)
            $removals | Should -HaveCount 1
            $removals[0].moduleName | Should -Match '/helper$'
            $sourcePath = Join-Path $sourceRoot $output.sourcePath
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($sourcePath))
            Copy-Item -LiteralPath (Join-Path $fixture.Legacy $output.sourceFile) -Destination $sourcePath
        }
        Write-AvmCatalogBundle -Bundle $bundle -OutputPath $fixture.Output -Configuration $configuration | Out-Null
        $publicationRemovals = Get-AvmCatalogPublicationRowRemovals -BundlePath $fixture.Output `
            -Configuration $configuration -SourceRoot $sourceRoot
        $publicationRemovals | Should -HaveCount 6
        $plan = [ordered]@{ schemaVersion = 1; manifestHash = $configuration.hash; outputHashes = [ordered]@{} }
        $paths = Get-AvmCatalogPublicationPaths -Configuration $configuration
        foreach ($role in $paths.Keys) {
            $plan[$role] = [ordered]@{ repository = $paths[$role].repository; baseFiles = [ordered]@{} }
            foreach ($relative in $paths[$role].basePaths) {
                $sourcePath = Join-Path $sourceRoot $relative
                $plan[$role].baseFiles[$relative] = if (Test-Path -LiteralPath $sourcePath) {
                    (Get-FileHash -LiteralPath $sourcePath).Hash.ToLowerInvariant()
                } else { $null }
            }
        }
        foreach ($relative in $bundle.Files.Keys) {
            $plan.outputHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $fixture.Output $relative)).Hash.ToLowerInvariant()
        }
        Save-CatalogJson -Path (Join-Path $fixture.Output (Get-AvmCatalogOutput -Configuration $configuration -Kind publication-plan).bundlePath) -Data $plan
        { Test-AvmCatalogPublicationBundle -Path $fixture.Output -Configuration $configuration } |
            Should -Throw '*CSV row removals are blocked*'
        $publishedPlan = Test-AvmCatalogPublicationBundle -Path $fixture.Output -Configuration $configuration -Force
        $publishedPlan.outputHashes.Count | Should -Be 9
    }
}

Describe 'Component: module catalog transformations' -Tag Component {
    It 'uses Bicep metadata descriptions without enforcing main.bicep literal parity' {
        $fixture = New-CatalogFixture -AdoptAll
        $module = @($fixture.Modules | Where-Object {
                $_.Ecosystem -eq 'bicep' -and $_.ModuleType -eq 'resource'
            })[0]
        [System.IO.File]::WriteAllText(
            (Join-Path $module.Directory 'main.bicep'),
            "metadata name = 'Authoritative module'`nmetadata description = 'Bicep source description.'`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $inventory = Get-CatalogFixtureInventory -Fixture $fixture
        $item = @($inventory.Items | Where-Object { $_.Identity.Key -eq $module.Identity.Key })[0]

        $item.Record.moduleDescription | Should -BeExactly 'Deploys reviewed module.'
    }

    It 'projects Oracle <ResourceType> into resource catalog records and CSV rows' -TestCases @(
        @{ ResourceType = 'cloudExadataInfrastructures' }
        @{ ResourceType = 'cloudVmClusters' }
        @{ ResourceType = 'autonomousDatabases' }
    ) {
        param($ResourceType)
        $fixture = New-CatalogFixture -AdoptAll
        $canonical = "Oracle.Database/$ResourceType"
        $rootPaths = @{ bicep = 'avm/res/oracle/database'; terraform = '.' }
        foreach ($ecosystem in @('bicep', 'terraform')) {
            $repository = if ($ecosystem -eq 'bicep') { 'Azure/bicep-registry-modules' } else { 'Azure/terraform-azurerm-avm-res-oracle-database' }
            $rootPath = $rootPaths[$ecosystem]
            $null = Add-CatalogModule -Fixture $fixture -Ecosystem $ecosystem -Repository $repository `
                -ModulePath $rootPath -Canonical $canonical -Adopt
            $childPath = if ($ecosystem -eq 'bicep') { "$rootPath/child" } else { 'modules/child' }
            $child = Add-CatalogModule -Fixture $fixture -Ecosystem $ecosystem -Repository $repository `
                -ModulePath $childPath -Canonical $canonical -Child -Adopt
            if ($ecosystem -eq 'bicep') {
                $metadata = Read-AvmCatalogJson -Path (Join-Path $child.Directory 'metadata.json')
                $metadata.Remove('telemetryIdPrefix')
                Save-CatalogJson -Path (Join-Path $child.Directory 'metadata.json') -Data $metadata
            }
        }
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $published = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
        foreach ($ecosystem in @('bicep', 'terraform')) {
            $records = $published.modules[$canonical][$ecosystem]
            $records | Should -HaveCount 2
            $root = @($records | Where-Object { $null -eq $_.parentModule })[0]
            $child = @($records | Where-Object { $null -ne $_.parentModule })[0]
            $child.parentModule | Should -BeExactly $rootPaths[$ecosystem]
            $child.familyModule | Should -BeExactly $rootPaths[$ecosystem]
            ConvertTo-AvmCatalogJson -Value $child.owners | Should -BeExactly (ConvertTo-AvmCatalogJson -Value $root.owners)
            Get-CatalogOwnerHandles $root.owners | Should -Be @('owner-one', 'owner-two', 'owner-three', '@Azure/avm-core-modules')
            foreach ($record in $records) {
                $record.moduleType | Should -BeExactly 'resource'
                $record.canonicalType | Should -BeExactly $canonical
                $record.providerNamespace | Should -BeExactly 'Oracle.Database'
                $record.resourceType | Should -BeExactly $ResourceType
                $record.provider | Should -Be $(if ($ecosystem -eq 'terraform') { 'azurerm' } else { $null })
                $record.Contains('tier') | Should -BeFalse
            }
            if ($ecosystem -eq 'bicep') { $child.telemetryIdPrefix | Should -BeNullOrEmpty }
            $file = if ($ecosystem -eq 'bicep') { 'BicepResourceModules.csv' } else { 'TerraformResourceModules.csv' }
            $rows = @($bundle.Files["docs/$file"] | ConvertFrom-Csv | Where-Object {
                    $_.ProviderNamespace -ceq 'Oracle.Database' -and $_.ResourceType -ceq $ResourceType
                })
            # Terraform submodule rows are excluded from the CSV, so only the root row is expected.
            $rows | Should -HaveCount $(if ($ecosystem -eq 'bicep') { 2 } else { 1 })
            foreach ($row in $rows) {
                $row.ProviderNamespace | Should -BeExactly 'Oracle.Database'
                $row.ResourceType | Should -BeExactly $ResourceType
            }
            $published.modules['Microsoft.Storage/storageAccounts'][$ecosystem] | Should -HaveCount 1
        }
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
    }

    It 'rejects malformed Oracle or synthetic ARM types in catalog keys and records: <Canonical>' -TestCases @(
        @{ Canonical = 'Oracle.Database' }
        @{ Canonical = 'oracle.Database/cloudVmClusters' }
        @{ Canonical = 'Oracle.database/cloudVmClusters' }
        @{ Canonical = 'Oracle.Other/cloudVmClusters' }
        @{ Canonical = 'Oracle.Database.Extra/cloudVmClusters' }
        @{ Canonical = 'Contoso.Database/cloudVmClusters' }
        @{ Canonical = 'Oracle.Database//cloudVmClusters' }
        @{ Canonical = 'Oracle.Database/cloudVmClusters/Microsoft.Insights/diagnosticSettings' }
        @{ Canonical = 'Microsoft.Storage/storageAccounts/Microsoft.Insights/diagnosticSettings' }
    ) {
        param($Canonical)
        $fixture = New-CatalogFixture -AdoptAll
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $schema = (Get-AvmCatalogOutput -Configuration $bundle.Configuration -Kind catalog).schema
        foreach ($surface in @('key', 'record')) {
            $catalog = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
            $key = 'Microsoft.Storage/storageAccounts'
            if ($surface -eq 'key') {
                $catalog.modules[$Canonical] = $catalog.modules[$key]
                $catalog.modules.Remove($key)
            }
            else {
                $catalog.modules[$key].terraform[0].canonicalType = $Canonical
            }
            Test-Json -Json (ConvertTo-AvmCatalogJson -Value $catalog) -SchemaFile (Join-Path $repoRoot $schema) `
                -ErrorAction SilentlyContinue | Should -BeFalse
        }
    }

    It 'retains grouped Bicep identity requirements for <Kind>' -TestCases @(
        @{ Kind = 'res' }, @{ Kind = 'ptn' }, @{ Kind = 'utl' }
    ) {
        param($Kind)
        { New-AvmCatalogIdentity -Ecosystem bicep -Repository Azure/bicep-registry-modules -ModulePath "avm/$Kind/example" } |
            Should -Throw '*Unsupported Bicep identity*'
    }

    It 'groups single-segment <ModuleType> canonical types without changing root or child identities' -TestCases @(
        @{ ModuleType = 'pattern'; Canonical = 'alz' }
        @{ ModuleType = 'utility'; Canonical = 'naming' }
    ) {
        param($ModuleType, $Canonical)
        $fixture = New-CatalogFixture -AdoptAll
        foreach ($module in @($fixture.Modules | Where-Object ModuleType -eq $ModuleType)) {
            $metadata = Read-AvmCatalogJson -Path (Join-Path $module.Directory 'metadata.json')
            $metadata.canonicalType = $Canonical
            if ($ModuleType -eq 'utility') { $metadata.Remove('telemetryIdPrefix') }
            Save-CatalogJson -Path (Join-Path $module.Directory 'metadata.json') -Data $metadata
            $childPath = if ($module.Ecosystem -eq 'bicep') { "$($module.ModulePath)/child" } else { 'modules/child' }
            $child = Add-CatalogModule -Fixture $fixture -Ecosystem $module.Ecosystem -Repository $module.Repository `
                -ModulePath $childPath -Canonical $Canonical -Child -Adopt
            if ($ModuleType -eq 'utility') {
                $metadata = Read-AvmCatalogJson -Path (Join-Path $child.Directory 'metadata.json')
                $metadata.Remove('telemetryIdPrefix')
                Save-CatalogJson -Path (Join-Path $child.Directory 'metadata.json') -Data $metadata
            }
        }
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        foreach ($ecosystem in @('bicep', 'terraform')) {
            $records = $bundle.Catalog.modules[$Canonical][$ecosystem]
            $records | Should -HaveCount 2
            $root = @($records | Where-Object { $null -eq $_.parentModule })[0]
            $child = @($records | Where-Object { $null -ne $_.parentModule })[0]
            $child.parentModule | Should -BeExactly $root.modulePath
            $child.familyModule | Should -BeExactly $root.modulePath
            ConvertTo-AvmCatalogJson -Value $child.owners | Should -BeExactly (ConvertTo-AvmCatalogJson -Value $root.owners)
            foreach ($record in $records) {
                ($null -eq $record.providerNamespace) | Should -BeTrue
                ($null -eq $record.resourceType) | Should -BeTrue
                if ($ModuleType -eq 'utility') { ($null -eq $record.telemetryIdPrefix) | Should -BeTrue }
            }
            $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'][$ecosystem] | Should -HaveCount 1
        }
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
    }

    It 'keeps catalog resource and non-resource canonical types separate: <ModuleType>' -TestCases @(
        @{ ModuleType = 'resource'; Canonical = 'naming' }
        @{ ModuleType = 'utility'; Canonical = 'Microsoft.Storage/storageAccounts' }
        @{ ModuleType = 'utility'; Canonical = 'Oracle.Database/autonomousDatabases' }
    ) {
        param($ModuleType, $Canonical)
        $fixture = New-CatalogFixture -AdoptAll
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $key = if ($ModuleType -eq 'resource') { 'Microsoft.Storage/storageAccounts' } else { 'types/common' }
        $bundle.Catalog.modules[$key].terraform[0].canonicalType = $Canonical
        $schema = (Get-AvmCatalogOutput -Configuration $bundle.Configuration -Kind catalog).schema
        Test-Json -Json (ConvertTo-AvmCatalogJson -Value $bundle.Catalog) -SchemaFile (Join-Path $repoRoot $schema) `
            -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'blocks source CSV row removal by default and emits no legacy records when forced' {
        $fixture = New-CatalogFixture
        $held = Get-CatalogFixtureBundle -Fixture $fixture
        $held.Report.csvRowRemovals | Should -HaveCount 6
        $held.HeldBack | Should -Contain 'docs/v1/modules.json'
        $held.HeldBackSourceFiles | Should -Contain 'BicepResourceModules.csv'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        foreach ($file in $fixture.Original.Keys) {
            $text = $bundle.Files["docs/$file"]
            ($text -split "`n")[0] | Should -BeExactly ($fixture.Headers[$file] -join ',')
            @($text | ConvertFrom-Csv) | Should -HaveCount 0
            $source = Read-AvmCatalogCsv -Path (Join-Path $fixture.Legacy $file)
            foreach ($column in $fixture.Headers[$file]) {
                $source.Rows[0][$column] | Should -BeExactly $fixture.Original[$file][$column]
            }
            $bundle.Report.sourceCsvRows[$file] | Should -HaveCount 1
        }
        $bundle.Catalog.modules.Count | Should -Be 0
        $bundle.Report.missingMetadata.Count | Should -Be 6
        $bundle.Report.csvRowRemovals | Should -HaveCount 6
        $bundle.Report.csvRowRemovalsForced | Should -BeTrue
        $bundle.Report.Contains('modes') | Should -BeFalse
        $bundle.Files['docs/BicepMARModules.json'] | ConvertFrom-Json | Should -HaveCount 3
    }

    It 'uses metadata per adopted module and resolves only the first two names from the profile cache' {
        $fixture = New-CatalogFixture
        Save-CatalogMetadata -Module $fixture.Modules[0]
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $row = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
        $row.ModuleDisplayName | Should -BeExactly 'Authoritative module'
        $row.Description | Should -BeExactly 'Deploys reviewed module.'
        $row.AlternativeNames | Should -BeExactly 'Alias one, Alias two'
        $row.Comments | Should -BeExactly 'Reviewed comment.'
        $row.PSObject.Properties.Name | Should -Not -Contain 'Tier'
        $row.PrimaryModuleOwnerGHHandle | Should -BeExactly 'owner-one'
        $row.SecondaryModuleOwnerGHHandle | Should -BeExactly 'owner-two'
        $row.PrimaryModuleOwnerDisplayName | Should -BeExactly 'Profile One'
        $row.SecondaryModuleOwnerDisplayName | Should -BeExactly 'Profile Two'
        $row.ModuleStatus | Should -BeExactly 'Available'
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].owners | Should -HaveCount 4
        $published = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
        $publishedOwners = @($published.modules['Microsoft.Storage/storageAccounts'].bicep[0].owners)
        Get-CatalogOwnerHandles $publishedOwners | Should -Be @('owner-one', 'owner-two', 'owner-three', '@Azure/avm-core-modules')
        $publishedOwners[0].handle | Should -BeExactly 'owner-one'
        $publishedOwners[0].type | Should -BeExactly 'user'
        $publishedOwners[0].displayName | Should -BeExactly 'Profile One'
        $publishedOwners[2].handle | Should -BeExactly 'owner-three'
        $publishedOwners[2].type | Should -BeExactly 'user'
        $publishedOwners[2].displayName | Should -BeNullOrEmpty
        $publishedOwners[3].handle | Should -BeExactly '@Azure/avm-core-modules'
        $publishedOwners[3].type | Should -BeExactly 'team'
        $publishedOwners[3].displayName | Should -BeExactly 'Maintains AVM core modules.'
        @($bundle.Files['docs/TerraformResourceModules.csv'] | ConvertFrom-Csv) | Should -HaveCount 0
        $bundle.Report.csvRowRemovals | Should -HaveCount 5
        $bundle.Report.csvRowRemovals.moduleName | Should -Not -Contain $fixture.Modules[0].Identity.ModuleName
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].metadataSource | Should -BeExactly 'metadata'
    }

    It 'accepts a display name that differs from the Bicep source literal' {
        $fixture = New-CatalogFixture
        $module = $fixture.Modules[0]
        Save-CatalogMetadata -Module $module
        $path = Join-Path $module.Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $path
        $metadata.moduleDisplayName = 'Catalog display name'
        Save-CatalogJson -Path $path -Data $metadata
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $row = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
        $row.ModuleDisplayName | Should -BeExactly 'Catalog display name'
        $row.Description | Should -BeExactly 'Deploys reviewed module.'
    }

    It 'does not fall back or write outputs for invalid present metadata: <Kind>' -TestCases @(
        @{ Kind = 'json' }, @{ Kind = 'schema' }, @{ Kind = 'bom' }
    ) {
        param($Kind)
        $fixture = New-CatalogFixture
        $module = $fixture.Modules[0]
        Save-CatalogMetadata -Module $module
        $path = Join-Path $module.Directory 'metadata.json'
        switch ($Kind) {
            'json' { [System.IO.File]::WriteAllText($path, '{"schemaVersion":') }
            'schema' {
                $metadata = Read-AvmCatalogJson -Path $path
                $metadata['moduleType'] = 'resource'
                Save-CatalogJson -Path $path -Data $metadata
            }
            'bom' {
                [System.IO.File]::WriteAllText($path, [System.IO.File]::ReadAllText($path), [System.Text.UTF8Encoding]::new($true))
            }
        }
        foreach ($force in @($false, $true)) {
            { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output -Force:$force } |
                Should -Throw '*Invalid present metadata*'
            Test-Path -LiteralPath $fixture.Output | Should -BeFalse
        }
    }

    It 'inherits family owners while keeping immediate Bicep and Terraform parent identities' {
        $fixture = New-CatalogFixture -AdoptAll
        $child = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/blob-service' -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/blob-service/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azurerm-avm-res-storage-storageaccount' `
            -ModulePath 'modules/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $entry = $bundle.Catalog.modules['Microsoft.Storage/storageAccounts/blobServices/containers']
        $entry.bicep[0].modulePath | Should -BeExactly 'avm/res/storage/storage-account/blob-service/container'
        $entry.terraform[0].modulePath | Should -BeExactly 'modules/container'
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].modulePath | Should -BeExactly 'avm/res/storage/storage-account'
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].terraform[0].modulePath | Should -BeExactly '.'
        $entry.bicep[0].parentModule | Should -BeExactly $child.ModulePath
        $entry.bicep[0].familyModule | Should -BeExactly 'avm/res/storage/storage-account'
        $entry.bicep[0].resourceType | Should -BeExactly 'storageAccounts/blobServices/containers'
        $entry.terraform[0].parentModule | Should -BeExactly '.'
        $entry.terraform[0].moduleName | Should -BeExactly 'avm-res-storage-storageaccount//modules/container'
        $entry.terraform[0].publicRegistryReference | Should -BeExactly 'https://registry.terraform.io/modules/Azure/avm-res-storage-storageaccount/azurerm/1.2.3/submodules/container'
        $entry.terraform[0].Contains('tier') | Should -BeFalse
        $entry.terraform[0].owners | Should -HaveCount 4
        $entry.bicep[0].alternativeNames | Should -Be @('Alias one', 'Alias two')
        $entry.bicep[0].comments | Should -BeExactly 'Reviewed comment.'
        $entry.terraform[0].alternativeNames | Should -Be @('Alias one', 'Alias two')
        $entry.terraform[0].comments | Should -BeExactly 'Reviewed comment.'
        $terraformSubmoduleRows = @($bundle.Files['docs/TerraformResourceModules.csv'] | ConvertFrom-Csv | Where-Object { $_.ModuleName -like '*//modules/*' })
        $terraformSubmoduleRows | Should -BeNullOrEmpty
        $bicepRow = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv | Where-Object { $_.ModuleName -eq $entry.bicep[0].moduleName })[0]
        $bicepRow.ParentModule | Should -BeExactly 'avm/res/storage/storage-account'
        $childRows = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv | Where-Object { $_.ParentModule -ne 'n/a' })
        $childRows | Should -Not -BeNullOrEmpty
        foreach ($childRow in $childRows) {
            $childRow.AlternativeNames | Should -BeExactly ''
            $childRow.Comments | Should -BeExactly ''
        }
        $published = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
        foreach ($canonical in @('Microsoft.Storage/storageAccounts', 'Microsoft.Storage/storageAccounts/blobServices/containers')) {
            foreach ($ecosystem in @('bicep', 'terraform')) {
                $publishedOwners = @($published.modules[$canonical][$ecosystem][0].owners)
                Get-CatalogOwnerHandles $publishedOwners | Should -Be @('owner-one', 'owner-two', 'owner-three', '@Azure/avm-core-modules')
            }
        }
    }

    It 'orders every CSV output alphabetically by module name regardless of discovery order' {
        $fixture = New-CatalogFixture -AdoptAll
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/zeta-account' -Canonical 'Microsoft.Storage/zetaAccounts' -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/alpha-account' -Canonical 'Microsoft.Storage/alphaAccounts' -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azurerm-avm-res-storage-zetaaccount' `
            -ModulePath '.' -Canonical 'Microsoft.Storage/zetaAccounts' -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azurerm-avm-res-storage-alphaaccount' `
            -ModulePath '.' -Canonical 'Microsoft.Storage/alphaAccounts' -Adopt
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        foreach ($file in @('BicepResourceModules.csv', 'TerraformResourceModules.csv')) {
            $names = @(($bundle.Files["docs/$file"] | ConvertFrom-Csv).ModuleName)
            $sorted = [string[]]$names.Clone()
            [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
            $names | Should -Be $sorted
        }
    }

    It 'excludes Terraform submodule rows from the CSV even when a legacy row exists' {
        $fixture = New-CatalogFixture -AdoptAll
        $child = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azurerm-avm-res-storage-storageaccount' `
            -ModulePath 'modules/blob-service' -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
        $file = 'TerraformResourceModules.csv'
        $legacyRow = [ordered]@{}
        foreach ($header in $fixture.Headers[$file]) {
            $legacyRow[$header] = $fixture.Original[$file][$header]
        }
        $legacyRow.ModuleName = $child.Identity.ModuleName
        $legacyRow.RepoURL = $child.Identity.RepoURL
        $legacyRow.ParentModule = 'avm-res-storage-storageaccount'
        $legacyRow.ResourceType = 'storageAccounts/blobServices'
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $legacyRow)))

        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $rows = @($bundle.Files["docs/$file"] | ConvertFrom-Csv | Where-Object { $_.ModuleName -ceq $child.Identity.ModuleName })
        $rows | Should -BeNullOrEmpty
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts/blobServices'].terraform[0].moduleName |
            Should -BeExactly $child.Identity.ModuleName
    }

    It 'preserves <Ecosystem> child CSV aliases and comments when existing cells are <CellContent>' -TestCases @(
        @{ Ecosystem = 'bicep'; CellContent = 'populated' }
        @{ Ecosystem = 'bicep'; CellContent = 'empty' }
        @{ Ecosystem = 'terraform'; CellContent = 'populated' }
        @{ Ecosystem = 'terraform'; CellContent = 'empty' }
    ) {
        param($Ecosystem, $CellContent)
        $fixture = New-CatalogFixture -AdoptAll
        $repository = if ($Ecosystem -eq 'bicep') { 'Azure/bicep-registry-modules' } else { 'Azure/terraform-azurerm-avm-res-storage-storageaccount' }
        $modulePath = if ($Ecosystem -eq 'bicep') { 'avm/res/storage/storage-account/blob-service' } else { 'modules/blob-service' }
        $file = if ($Ecosystem -eq 'bicep') { 'BicepResourceModules.csv' } else { 'TerraformResourceModules.csv' }
        $child = Add-CatalogModule -Fixture $fixture -Ecosystem $Ecosystem -Repository $repository `
            -ModulePath $modulePath -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
        $legacyRow = [ordered]@{}
        foreach ($header in $fixture.Headers[$file]) {
            $legacyRow[$header] = $fixture.Original[$file][$header]
        }
        $legacyRow.ModuleName = $child.Identity.ModuleName
        $legacyRow.RepoURL = $child.Identity.RepoURL
        $legacyRow.ParentModule = if ($Ecosystem -eq 'bicep') { 'avm/res/storage/storage-account' } else { 'avm-res-storage-storageaccount' }
        $legacyRow.ResourceType = 'storageAccounts/blobServices'
        $legacyRow.AlternativeNames = if ($CellContent -eq 'populated') { ' Child alias, "quoted", another alias ' } else { '' }
        $legacyRow.Comments = if ($CellContent -eq 'populated') { " Child-only note, `"quoted`".`nKeep this second line. " } else { '' }
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $legacyRow)))

        foreach ($force in @($false, $true)) {
            $inventory = Get-CatalogFixtureInventory -Fixture $fixture
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory -Force:$force
            if ($Ecosystem -eq 'terraform') {
                # Terraform submodule rows are intentionally excluded from the CSV, so the legacy
                # child row is always treated as removed: held back without -Force, dropped with it.
                # The JSON catalog entry still inherits family alternativeNames/comments/owners.
                if ($force) {
                    $childRows = @($bundle.Files["docs/$file"] | ConvertFrom-Csv | Where-Object { $_.ModuleName -ceq $child.Identity.ModuleName })
                    $childRows | Should -BeNullOrEmpty
                }
                else {
                    $bundle.HeldBackSourceFiles | Should -Contain $file
                }
                $entry = $bundle.Catalog.modules['Microsoft.Storage/storageAccounts/blobServices'][$Ecosystem][0]
                $entry.owners | Should -HaveCount 4
                $entry.alternativeNames | Should -Be @('Alias one', 'Alias two')
                $entry.comments | Should -BeExactly 'Reviewed comment.'
                continue
            }
            $childRows = @($bundle.Files["docs/$file"] | ConvertFrom-Csv | Where-Object { $_.ModuleName -ceq $child.Identity.ModuleName })
            $childRows | Should -HaveCount 1
            $childRows[0].AlternativeNames | Should -BeExactly $legacyRow.AlternativeNames
            $childRows[0].Comments | Should -BeExactly $legacyRow.Comments
            $childRows[0].PrimaryModuleOwnerGHHandle | Should -BeExactly 'owner-one'
            $childRows[0].SecondaryModuleOwnerGHHandle | Should -BeExactly 'owner-two'
            $entry = $bundle.Catalog.modules['Microsoft.Storage/storageAccounts/blobServices'][$Ecosystem][0]
            $entry.owners | Should -HaveCount 4
            $entry.alternativeNames | Should -Be @('Alias one', 'Alias two')
            $entry.comments | Should -BeExactly 'Reviewed comment.'
        }
    }

    It 'refuses a reduced child whose family metadata is missing' {
        $fixture = New-CatalogFixture
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azurerm-avm-res-storage-storageaccount' `
            -ModulePath 'modules/child' -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
        { Get-CatalogFixtureInventory -Fixture $fixture } | Should -Throw '*family root metadata is missing*'
    }

    It 'supports team-only ownership and telemetry-free utilities without guessing owner names' {
        $fixture = New-CatalogFixture -AdoptAll
        $path = Join-Path $fixture.Modules[2].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $path
        $metadata.owners = @('@Azure/avm-core-modules')
        $metadata.Remove('telemetryIdPrefix')
        Save-CatalogJson -Path $path -Data $metadata
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $record = $bundle.Catalog.modules['types/common'].bicep[0]
        Get-CatalogOwnerHandles $record.owners | Should -Be @('@Azure/avm-core-modules')
        $record.owners[0].handle | Should -BeExactly '@Azure/avm-core-modules'
        $record.owners[0].type | Should -BeExactly 'team'
        $record.owners[0].displayName | Should -BeExactly 'Maintains AVM core modules.'
        $record.telemetryIdPrefix | Should -BeNullOrEmpty
        $row = @($bundle.Files['docs/BicepUtilityModules.csv'] | ConvertFrom-Csv)[0]
        $row.PrimaryModuleOwnerGHHandle | Should -BeExactly ''
        $row.PrimaryModuleOwnerDisplayName | Should -BeExactly ''
        $row.SecondaryModuleOwnerGHHandle | Should -BeExactly ''
        $row.ModuleOwnersGHTeam | Should -BeExactly '@Azure/avm-core-modules'
    }

    It 'preserves an empty alternatives array when optional root fields are <Shape>' -TestCases @(
        @{ Shape = 'absent' }, @{ Shape = 'empty' }
    ) {
        param($Shape)
        $fixture = New-CatalogFixture -AdoptAll
        $path = Join-Path $fixture.Modules[0].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $path
        $metadata.Remove('comments')
        $metadata.owners = @('owner-one')
        if ($Shape -eq 'absent') {
            $metadata.Remove('alternativeNames')
        }
        else {
            $metadata.alternativeNames = @()
        }
        Save-CatalogJson -Path $path -Data $metadata
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $record = $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0]
        $record.alternativeNames | Should -HaveCount 0
        $record.comments | Should -BeExactly ''
        Get-CatalogOwnerHandles $record.owners | Should -Be @('owner-one')
    }

    It 'keeps multiple Terraform provider implementations under the same canonical key' {
        $fixture = New-CatalogFixture -AdoptAll
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azure-avm-res-storage-storageaccount' `
            -ModulePath '.' -Canonical 'Microsoft.Storage/storageAccounts' -Adopt
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $implementations = $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].terraform
        $implementations | Should -HaveCount 2
        $implementations.provider | Should -Contain 'azure'
        $implementations.provider | Should -Contain 'azurerm'
        @($bundle.Files['docs/TerraformResourceModules.csv'] | ConvertFrom-Csv) | Should -HaveCount 2
    }

    It 'derives canonical types and parity from metadata without using legacy taxonomy' {
        $fixture = New-CatalogFixture -AdoptAll
        foreach ($module in @($fixture.Modules | Where-Object { $_.Ecosystem -eq 'terraform' -and $_.ModuleType -ne 'resource' })) {
            $path = Join-Path $module.Directory 'metadata.json'
            $metadata = Read-AvmCatalogJson -Path $path
            $metadata.canonicalType = "terraform/$($module.ModuleType)"
            Save-CatalogJson -Path $path -Data $metadata
        }
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Report.parity.bicepOnly | Should -Contain 'lz/sub-vending'
        $bundle.Report.parity.bicepOnly | Should -Contain 'types/common'
        $bundle.Report.unresolvedLegacy | Should -HaveCount 0
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azapi-avm-res-compute-disk' `
            -ModulePath '.' -Canonical 'Microsoft.Compute/disks' -Adopt
        (Get-CatalogFixtureBundle -Fixture $fixture).Report.parity.terraformOnly | Should -Contain 'Microsoft.Compute/disks'
    }

    It 'protects source rows across both ecosystems without mode options' {
        $fixture = New-CatalogFixture
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBack | Should -Contain 'docs/v1/modules.json'
        foreach ($module in @($fixture.Modules | Where-Object { $_.Ecosystem -eq 'bicep' })) {
            Save-CatalogMetadata -Module $module
        }
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBackSourceFiles | Should -Contain 'TerraformResourceModules.csv'
        foreach ($module in @($fixture.Modules | Where-Object { $_.Ecosystem -eq 'terraform' })) {
            Save-CatalogMetadata -Module $module
        }
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
        $bundle.Report.csvRowRemovalsForced | Should -BeFalse
        foreach ($command in @((Get-Command Get-AvmCatalogInventory), (Get-Command (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1')))) {
            $command.Parameters.Keys | Should -Not -Contain 'BicepMode'
            $command.Parameters.Keys | Should -Not -Contain 'TerraformMode'
        }
    }

    It 'does not read or publish repository configuration or generate tier metadata' {
        $fixture = New-CatalogFixture -AdoptAll
        $configurationPath = Join-Path $fixture.Root 'repository-config.json'
        [System.IO.File]::WriteAllText($configurationPath, 'not a catalog input')
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Files.Count | Should -Be 9
        @($bundle.Files.Keys | Where-Object { $_ -notlike 'docs/*' }) | Should -Be @('v1/migration-report.json')
        $published = Read-AvmCatalogJson -Path (Join-Path $fixture.Modules[0].Directory 'metadata.json')
        $published.Contains('tier') | Should -BeFalse
        foreach ($implementations in $bundle.Catalog.modules.Values) {
            foreach ($record in @($implementations.bicep) + @($implementations.terraform)) {
                $record.Contains('tier') | Should -BeFalse
            }
        }
        $null = & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output
        [System.IO.File]::ReadAllText($configurationPath) | Should -BeExactly 'not a catalog input'
        Test-Path (Join-Path $fixture.Output 'tools') | Should -BeFalse
    }

    It 'keeps known future columns and avoids duplicate headers when consuming a previously generated CSV' {
        $fixture = New-CatalogFixture -AdoptAll
        $file = 'BicepResourceModules.csv'
        $row = $fixture.Original[$file]
        $row['FutureColumn'] = 'retain future data'
        $row['CanonicalType'] = ''
        $headers = $fixture.Headers[$file] + @('FutureColumn', 'CanonicalType')
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file), (ConvertTo-AvmCatalogCsv -Headers $headers -Rows @($row)))
        $text = (Get-CatalogFixtureBundle -Fixture $fixture).Files["docs/$file"]
        ($text -split "`n")[0] | Should -BeExactly ($headers -join ',')
        @($text | ConvertFrom-Csv)[0].FutureColumn | Should -BeExactly 'retain future data'
    }

    It 'produces deterministic LF UTF-8 without BOM and never overwrites an existing output directory' {
        $fixture = New-CatalogFixture -AdoptAll
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $second = Get-CatalogFixtureBundle -Fixture $fixture
        foreach ($relative in $bundle.Files.Keys) {
            $bundle.Files[$relative] | Should -BeExactly $second.Files[$relative]
        }
        $null = Write-AvmCatalogBundle -Bundle $bundle -OutputPath $fixture.Output
        foreach ($file in @(Get-ChildItem -LiteralPath $fixture.Output -Recurse -File)) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $bytes | Should -Not -Contain 13
            [Convert]::ToHexString($bytes[0..2]) | Should -Not -Be 'EFBBBF'
        }
        { Write-AvmCatalogBundle -Bundle $bundle -OutputPath $fixture.Output } | Should -Throw '*new directory*'
    }

    It 'orders newly discovered children deterministically regardless of file creation order' {
        $fixtures = @((New-CatalogFixture -AdoptAll), (New-CatalogFixture -AdoptAll))
        for ($index = 0; $index -lt 2; $index++) {
            $names = if ($index -eq 0) { @('alpha', 'zeta') } else { @('zeta', 'alpha') }
            foreach ($name in $names) {
                $null = Add-CatalogModule -Fixture $fixtures[$index] -Ecosystem terraform -Repository 'Azure/terraform-azurerm-avm-res-storage-storageaccount' `
                    -ModulePath "modules/$name" -Canonical "Microsoft.Storage/storageAccounts/$name" -Child -Adopt
            }
        }
        $first = Get-CatalogFixtureBundle -Fixture $fixtures[0]
        $second = Get-CatalogFixtureBundle -Fixture $fixtures[1]
        foreach ($relative in $first.Files.Keys) {
            $first.Files[$relative] | Should -BeExactly $second.Files[$relative]
        }
    }

    It 'supports header-only legacy files and reports undisclosed module identity instead of inventing records' {
        $fixture = New-CatalogFixture
        foreach ($file in $fixture.Headers.Keys) {
            [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file), (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @()))
        }
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Catalog.modules.Count | Should -Be 0
        $bundle.Report.missingMetadata | Should -HaveCount 6
        foreach ($file in $fixture.Headers.Keys) {
            @($bundle.Files["docs/$file"] | ConvertFrom-Csv) | Should -HaveCount 0
        }
    }

    It 'uses one modified manifest for collection, generation, and publication without legacy hard-coded paths' {
        $fixture = New-CatalogFixture -AdoptAll
        $raw = Read-AvmCatalogJson -Path (Join-Path $catalogScripts '..' 'config.json')
        $raw.repositories.docs = 'Azure/catalog-fixture'
        $raw.repositories.bicep = 'Azure/bicep-fixture'
        $raw.repositories.tools = 'Azure/tools-fixture'
        $raw.destinations.docs.path = 'docs/static/custom-indexes'
        $raw.outputs[0].file = 'RenamedBicepResources.csv'
        $raw.outputs[0].sourceFile = 'LegacyBicepResources.csv'
        ($raw.outputs | Where-Object kind -eq 'catalog').file = 'custom/catalog.json'
        ($raw.outputs | Where-Object kind -eq 'migration-report').file = 'custom/migration.json'
        ($raw.outputs | Where-Object kind -eq 'publication-plan').file = 'control/publication.json'
        $configurationPath = Join-Path $fixture.Root 'manifest.json'
        Save-CatalogJson -Path $configurationPath -Data $raw
        $configuration = Read-AvmCatalogConfiguration -Path $configurationPath
        Move-Item -LiteralPath (Join-Path $fixture.Legacy 'BicepResourceModules.csv') `
            -Destination (Join-Path $fixture.Legacy 'LegacyBicepResources.csv')
        $inventory = Get-AvmCatalogInventory -BicepRoot $fixture.Bicep -TerraformRoot $fixture.Terraform `
            -LegacyPath $fixture.Legacy -Configuration $configuration
        $null = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory

        $roots = @{ docs = Join-Path $fixture.Root 'docs-checkout'; tools = Join-Path $fixture.Root 'tools-checkout' }
        foreach ($output in $configuration.outputs | Where-Object { $_.kind -in @('csv', 'mar') }) {
            $source = if ($output.kind -eq 'csv') {
                Join-Path $fixture.Legacy $output.sourceFile
            }
            else {
                Join-Path $fixture.Legacy $output.file
            }
            $targetPath = if ($output.kind -eq 'csv') { $output.sourcePath } else { $output.targetPath }
            $target = Join-Path $roots[$output.destination] $targetPath
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
            [System.IO.File]::Copy($source, $target)
        }
        $inputPath = Join-Path $fixture.Root 'configured-input'
        $publication = Copy-AvmCatalogInputFile -Configuration $configuration -RepositoryRoots $roots -SnapshotPath $inputPath -Confirm:$false
        Copy-Item -LiteralPath (Join-Path $fixture.Root 'sources') -Destination (Join-Path $inputPath 'sources') -Recurse
        foreach ($name in @('registry.json', 'github.json', 'revisions.json')) {
            Copy-Item -LiteralPath (Join-Path $fixture.Root $name) -Destination (Join-Path $inputPath $name)
        }
        Save-CatalogJson -Path (Join-Path $inputPath 'publication.json') -Data $publication
        & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $inputPath `
            -OutputPath $fixture.Output -ConfigurationPath $configurationPath | Should -BeExactly ([System.IO.Path]::GetFullPath($fixture.Output))
        $plan = Test-AvmCatalogPublicationBundle -Path $fixture.Output -Configuration $configuration
        $plan.docs.repository | Should -BeExactly 'Azure/catalog-fixture'
        $plan.Contains('tools') | Should -BeFalse
        $plan.docs.baseFiles.Contains('docs/static/custom-indexes/custom/catalog.json') | Should -BeTrue
        $plan.docs.baseFiles.Contains('docs/static/custom-indexes/LegacyBicepResources.csv') | Should -BeTrue
        $plan.docs.baseFiles['docs/static/custom-indexes/RenamedBicepResources.csv'] | Should -BeNullOrEmpty
        $paths = @(Get-ChildItem -LiteralPath $fixture.Output -File -Recurse |
                ForEach-Object { [System.IO.Path]::GetRelativePath($fixture.Output, $_.FullName).Replace('\', '/') })
        @($paths | Sort-Object) | Should -Be @($configuration.outputs.bundlePath | Sort-Object)
        $catalog = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'docs' 'custom' 'catalog.json')
        $catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].repository | Should -BeExactly 'Azure/bicep-fixture'
        $paths | Should -Not -Contain 'docs/v1/modules.json'
        $paths | Should -Not -Contain 'tools/config.json'
    }

    It 'honors WhatIf without creating an output directory' {
        $fixture = New-CatalogFixture -AdoptAll
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output -WhatIf
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
    }

    It 'runs the real offline entry point and writes nothing for an incomplete registry or owner cache' {
        $fixture = New-CatalogFixture -AdoptAll
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        $cachePath = Join-Path $fixture.Root 'registry.json'
        Save-CatalogJson -Path $cachePath -Data @{}
        { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output } | Should -Throw '*Registry snapshot is incomplete*'
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        Save-CatalogJson -Path (Join-Path $fixture.Root 'github.json') -Data @{ users = @{}; teams = @{} }
        { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output } | Should -Throw '*profile cache is missing*'
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output | Should -BeExactly ([System.IO.Path]::GetFullPath($fixture.Output))
        @(Get-ChildItem -LiteralPath $fixture.Output -File -Recurse) | Should -HaveCount 9
    }

    It 'does not write output when generated registry data fails the output schema' {
        $fixture = New-CatalogFixture -AdoptAll
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        $registry = Read-AvmCatalogJson -Path (Join-Path $fixture.Root 'registry.json')
        $key = @($registry.Keys)[0]
        $registry[$key].currentVersion = $null
        Save-CatalogJson -Path (Join-Path $fixture.Root 'registry.json') -Data $registry
        { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output } | Should -Throw
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
    }

    It 'does not recreate an unowned legacy row without metadata even with force' {
        $fixture = New-CatalogFixture -AdoptAll
        $file = 'BicepResourceModules.csv'
        [System.IO.File]::Delete((Join-Path $fixture.Modules[0].Directory 'metadata.json'))
        $row = $fixture.Original[$file]
        $row.PrimaryModuleOwnerGHHandle = ''
        $row.SecondaryModuleOwnerGHHandle = ''
        $row.ModuleOwnersGHTeam = ''
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($row)))
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBackSourceFiles | Should -Contain 'BicepResourceModules.csv'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep | Should -HaveCount 0
        @($bundle.Files["docs/$file"] | ConvertFrom-Csv) | Should -HaveCount 0
        $bundle.Report.csvRowRemovals | Should -HaveCount 1
    }

    It 'derives <Ecosystem> status <Expected> from published=<Published>, owned=<Owned> and prior <Previous> in CSV and JSON' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($case in @(
                    @{ Published = $false; Owned = $false; Previous = 'Proposed'; Expected = 'Proposed' }
                    @{ Published = $false; Owned = $false; Previous = 'Orphaned'; Expected = 'Proposed' }
                    @{ Published = $false; Owned = $false; Previous = 'Available'; Expected = 'Proposed' }
                    @{ Published = $false; Owned = $true; Previous = 'Proposed'; Expected = 'Proposed' }
                    @{ Published = $true; Owned = $false; Previous = 'Proposed'; Expected = 'Orphaned' }
                    @{ Published = $true; Owned = $false; Previous = 'Available'; Expected = 'Orphaned' }
                    @{ Published = $true; Owned = $true; Previous = 'Proposed'; Expected = 'Available' }
                    @{ Published = $true; Owned = $true; Previous = 'Orphaned'; Expected = 'Available' }
                    @{ Published = $false; Owned = $false; Previous = 'Deprecated'; Expected = 'Excluded' }
                    @{ Published = $true; Owned = $false; Previous = 'Deprecated'; Expected = 'Deprecated' }
                )) {
                $case + @{ Ecosystem = $ecosystem }
            }
        }
    ) {
        param($Ecosystem, $Published, $Owned, $Previous, $Expected)
        $fixture = New-CatalogFixture -AdoptAll
        $file = if ($Ecosystem -eq 'bicep') { 'BicepResourceModules.csv' } else { 'TerraformResourceModules.csv' }
        $row = $fixture.Original[$file]
        $row.ModuleStatus = $Previous
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($row)))
        $module = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq 'resource' })[0]
        if (-not $Owned) {
            $path = Join-Path $module.Directory 'metadata.json'
            $metadata = Read-AvmCatalogJson -Path $path
            $metadata.owners = @()
            Save-CatalogJson -Path $path -Data $metadata
        }
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        if (-not $Published) {
            $registryPath = Join-Path $fixture.Root 'registry.json'
            $registry = Read-AvmCatalogJson -Path $registryPath
            $registry[$module.Identity.Key] = New-AvmCatalogRegistryResult -MarRegistered $registry[$module.Identity.Key].marRegistered
            Save-CatalogJson -Path $registryPath -Data $registry
        }
        & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output -WarningVariable warnings | Out-Null
        $catalog = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'docs' 'v1' 'modules.json')
        if ($Expected -eq 'Excluded') {
            $catalog.modules['Microsoft.Storage/storageAccounts'][$Ecosystem] | Should -HaveCount 0
            @(Import-Csv -LiteralPath (Join-Path $fixture.Output 'docs' $file)) | Should -HaveCount 0
            $warnings.Message | Should -BeLike "*Omitted deprecated, unpublished module $($module.Repository)*module path '$($module.ModulePath)'*Consider deleting*"
            $report = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'v1' 'migration-report.json')
            $report.excludedModules | Should -HaveCount 1
            $report.heldBackOutputs | Should -HaveCount 0
            $report.csvRowRemovalsForced | Should -BeFalse
            return
        }
        $catalog.modules['Microsoft.Storage/storageAccounts'][$Ecosystem][0].moduleStatus | Should -BeExactly $Expected
        (Import-Csv -LiteralPath (Join-Path $fixture.Output 'docs' $file)).ModuleStatus | Should -BeExactly $Expected
    }

    It 'excludes Bicep examples and nested Terraform helper scopes from module discovery' {
        $fixture = New-CatalogFixture -AdoptAll
        foreach ($directory in @(
                (Join-Path $fixture.Modules[0].Directory 'tests' 'e2e' 'defaults'),
                (Join-Path $fixture.Modules[0].Directory '.test' 'common'),
                (Join-Path $fixture.Modules[0].Directory 'modules' 'internal'),
                (Join-Path $fixture.Modules[3].Directory 'modules' 'parent' 'modules' 'nested')
            )) {
            $null = [System.IO.Directory]::CreateDirectory($directory)
            [System.IO.File]::WriteAllText((Join-Path $directory 'main.bicep'), 'not module source')
            [System.IO.File]::WriteAllText((Join-Path $directory 'main.tf'), 'not module source')
            [System.IO.File]::WriteAllText((Join-Path $directory 'metadata.json'), 'invalid and excluded')
        }
        (Get-CatalogFixtureInventory -Fixture $fixture).Sources | Should -HaveCount 6
    }

    It 'does not classify standalone Bicep helper files as publishable child modules' {
        $fixture = New-CatalogFixture -AdoptAll
        $helper = Join-Path $fixture.Modules[0].Directory 'helpers'
        $null = [System.IO.Directory]::CreateDirectory($helper)
        [System.IO.File]::WriteAllText((Join-Path $helper 'keyVaultExport.bicep'), 'param value string')
        (Get-CatalogFixtureInventory -Fixture $fixture).Sources | Should -HaveCount 6
    }

    It 'adopts scaffolded modules that have metadata but no source yet with owned=<Owned>' -TestCases @(
        @{ Owned = $true }
        @{ Owned = $false }
    ) {
        param($Owned)
        $fixture = New-CatalogFixture -AdoptAll
        $scaffolds = @{
            bicep = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
                -ModulePath 'avm/ptn/ai-ml/landing-zone' -Canonical 'ai-ml/landing-zone' -Adopt -SourcePending
            terraform = Add-CatalogModule -Fixture $fixture -Ecosystem terraform `
                -Repository 'Azure/terraform-azurerm-avm-ptn-ai-ml-landing-zone' `
                -ModulePath '.' -Canonical 'ai-ml/landing-zone' -Adopt -SourcePending
        }
        if (-not $Owned) {
            foreach ($scaffold in $scaffolds.Values) {
                $path = Join-Path $scaffold.Directory 'metadata.json'
                $metadata = Read-AvmCatalogJson -Path $path
                $metadata.owners = @()
                Save-CatalogJson -Path $path -Data $metadata
            }
        }

        $inventory = Get-CatalogFixtureInventory -Fixture $fixture
        $inventory.Report.missingMetadata | Should -HaveCount 0
        foreach ($scaffold in $scaffolds.Values) {
            $source = @($inventory.Sources | Where-Object { $_.Key -ceq $scaffold.Identity.Key })[0]
            $source | Should -Not -BeNullOrEmpty
            $source.SourcePending | Should -BeTrue
        }

        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory
        foreach ($ecosystem in @('bicep', 'terraform')) {
            $record = @($bundle.Catalog.modules['ai-ml/landing-zone'][$ecosystem])[0]
            $record.moduleStatus | Should -BeExactly 'Proposed'
            $record.moduleDisplayName | Should -BeExactly 'Authoritative module'
        }
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
    }

    It 'still refuses a published module whose source has gone missing' {
        $fixture = New-CatalogFixture -AdoptAll
        $scaffold = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/ptn/ai-ml/landing-zone' -Canonical 'ai-ml/landing-zone' -Adopt -SourcePending
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture
        $registry = [ordered]@{}
        foreach ($item in $inventory.Items) {
            $registry[$item.Identity.Key] = [ordered]@{
                status = 'available'; currentVersion = '1.2.3'; firstPublishedIn = '2024-02'
                downloads = $null; marRegistered = $true
            }
        }
        { New-AvmCatalogBundle -Inventory $inventory -Registry $registry -GitHub ([ordered]@{ users = @{}; teams = @{} }) `
                -RepositoryRevisions @() } |
            Should -Throw "*$($scaffold.Identity.Key)*registry reports it as available*"
    }

    It 'still rejects a Bicep source file whose name is not exactly main.bicep' {
        $fixture = New-CatalogFixture -AdoptAll
        $scaffold = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/ptn/ai-ml/landing-zone' -Canonical 'ai-ml/landing-zone' -Adopt -SourcePending
        [System.IO.File]::WriteAllText((Join-Path $scaffold.Directory 'Main.bicep'), "metadata name = 'Authoritative module'`n")
        { Get-CatalogFixtureInventory -Fixture $fixture } | Should -Throw '*has no main.bicep*'
    }
}

Describe 'Component: module catalog source CSV row retention' -Tag Component {
    It 'holds back outputs at the offline entry point and still honors WhatIf' {
        $fixture = New-CatalogFixture
        Save-CatalogMetadata -Module $fixture.Modules[0]
        $null = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $scriptPath = Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1'
        foreach ($force in @($null, $false)) {
            $arguments = @{ InputPath = $fixture.Root; OutputPath = $fixture.Output }
            if ($null -ne $force) { $arguments.Force = $force }
            & $scriptPath @arguments | Out-Null
            $blocked = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'v1' 'migration-report.json')
            $blocked.heldBackOutputs | Should -Contain 'docs/v1/modules.json'
            $blocked.csvRowRemovalsForced | Should -BeFalse
            [System.IO.Directory]::Delete($fixture.Output, $true)
        }
        & $scriptPath -InputPath $fixture.Root -OutputPath $fixture.Output -Force -WhatIf
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
        & $scriptPath -InputPath $fixture.Root -OutputPath $fixture.Output -Force | Out-Null
        $report = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'v1' 'migration-report.json')
        $report.csvRowRemovals | Should -HaveCount 5
        $report.heldBackOutputs | Should -HaveCount 0
        $report.csvRowRemovalsForced | Should -BeTrue
        $report.sourceCsvRows['BicepResourceModules.csv'][0].moduleName | Should -BeExactly $fixture.Modules[0].Identity.ModuleName
    }

    It 'detects a removed row even when an added module keeps the row count unchanged' {
        $fixture = New-CatalogFixture -AdoptAll
        [System.IO.File]::Delete((Join-Path $fixture.Modules[0].Directory 'metadata.json'))
        $replacement = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/key-vault/vault' -Canonical 'Microsoft.KeyVault/vaults' -Adopt
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBackSourceFiles | Should -Contain 'BicepResourceModules.csv'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $bundle.Report.counts.legacyRows['BicepResourceModules.csv'] | Should -Be 1
        $bundle.Report.counts.csvRows['BicepResourceModules.csv'] | Should -Be 1
        $bundle.Report.csvRowRemovals | Should -HaveCount 1
        $bundle.Report.csvRowRemovals[0].moduleName | Should -BeExactly $fixture.Modules[0].Identity.ModuleName
        @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)[0].ModuleName |
            Should -BeExactly $replacement.Identity.ModuleName
    }

    It 'distinguishes Terraform implementations that share a module name' {
        $fixture = New-CatalogFixture -AdoptAll
        [System.IO.File]::Delete((Join-Path $fixture.Modules[3].Directory 'metadata.json'))
        $replacement = Add-CatalogModule -Fixture $fixture -Ecosystem terraform `
            -Repository 'Azure/terraform-azure-avm-res-storage-storageaccount' -ModulePath '.' `
            -Canonical 'Microsoft.Storage/storageAccounts' -Adopt
        $replacement.Identity.ModuleName | Should -BeExactly $fixture.Modules[3].Identity.ModuleName
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBackSourceFiles | Should -Contain 'TerraformResourceModules.csv'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $bundle.Report.csvRowRemovals | Should -HaveCount 1
        $bundle.Report.csvRowRemovals[0].repoURL | Should -BeExactly $fixture.Modules[3].Identity.RepoURL
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].terraform[0].provider | Should -BeExactly 'azure'
    }

    It 'adopts a Terraform row whose repository moved to another provider prefix' {
        $fixture = New-CatalogFixture -AdoptAll
        $original = $fixture.Modules[3]
        [System.IO.Directory]::Delete($original.Directory, $true)
        $replacement = Add-CatalogModule -Fixture $fixture -Ecosystem terraform `
            -Repository 'Azure/terraform-azure-avm-res-storage-storageaccount' -ModulePath '.' `
            -Canonical 'Microsoft.Storage/storageAccounts' -Adopt
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
        $bundle.HeldBack | Should -HaveCount 0
        $bundle.Report.csvRowRenames | Should -HaveCount 1
        $bundle.Report.csvRowRenames[0].sourceFile | Should -BeExactly 'TerraformResourceModules.csv'
        $bundle.Report.csvRowRenames[0].fromRepoURL | Should -BeExactly $original.Identity.RepoURL
        $bundle.Report.csvRowRenames[0].toRepoURL | Should -BeExactly $replacement.Identity.RepoURL
        @($bundle.Files['docs/TerraformResourceModules.csv'] | ConvertFrom-Csv)[0].RepoURL |
            Should -BeExactly $replacement.Identity.RepoURL
    }

    It 'records why each held-back row was removed in the diagnostics report' {
        $fixture = New-CatalogFixture -AdoptAll
        [System.IO.File]::Delete((Join-Path $fixture.Modules[0].Directory 'metadata.json'))
        [System.IO.Directory]::Delete($fixture.Modules[3].Directory, $true)
        $diagnostics = Join-Path $fixture.Root 'diagnostics'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -DiagnosticsPath $diagnostics
        $bundle.HeldBack | Should -Contain 'docs/v1/modules.json'
        $report = Read-AvmCatalogJson -Path (Join-Path $diagnostics 'csv-row-removals.json')
        $report.heldBackSourceFiles | Should -Contain 'BicepResourceModules.csv'
        $reasons = @{}
        foreach ($removal in $report.removals) { $reasons[[string]$removal.moduleName] = [string]$removal.reason }
        $reasons[$fixture.Modules[0].Identity.ModuleName] | Should -BeExactly 'metadata-not-present'
        $reasons[$fixture.Modules[3].Identity.ModuleName] | Should -BeExactly 'module-source-not-found'
        $csv = @([System.IO.File]::ReadAllText((Join-Path $diagnostics 'csv-row-removals.csv')) -split "`n")
        $csv[0] | Should -BeExactly 'SourceFile,ModuleName,RepoURL,Reason,Published'
    }

    It 'protects a pre-source proposal with a <Identity> identity until force permits removal' -TestCases @(
        @{ Identity = 'resolvable'; Url = 'https://github.com/Azure/terraform-azurerm-avm-ptn-future-proposal' }
        @{ Identity = 'unresolved'; Url = '' }
    ) {
        param($Identity, $Url)
        $fixture = New-CatalogFixture -AdoptAll
        $file = 'TerraformPatternModules.csv'
        $proposal = [ordered]@{}
        foreach ($header in $fixture.Headers[$file]) { $proposal[$header] = $fixture.Original[$file][$header] }
        $proposal.ModuleName = 'avm-ptn-future-proposal'
        $proposal.RepoURL = $Url
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $proposal)))
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBackSourceFiles | Should -Contain 'TerraformPatternModules.csv'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        $bundle.Report.csvRowRemovals | Should -HaveCount 1
        $bundle.Report.csvRowRemovals[0].moduleName | Should -BeExactly 'avm-ptn-future-proposal'
        @($bundle.Files["docs/$file"] | ConvertFrom-Csv).ModuleName | Should -Not -Contain 'avm-ptn-future-proposal'
        if ($Identity -eq 'unresolved') {
            $bundle.Report.unresolvedLegacy | Should -HaveCount 1
        }
    }

    It 'compares only source rows for <Destination> outputs and ignores existing preview rows' -TestCases @(
        @{ Destination = 'preview' }
        @{ Destination = 'canonical' }
    ) {
        param($Destination)
        $fixture = New-CatalogFixture -AdoptAll
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy 'test-BicepResourceModules.csv'), 'not a source CSV')
        $raw = Read-AvmCatalogJson -Path (Join-Path $catalogScripts '..' 'config.json')
        if ($Destination -eq 'preview') {
            foreach ($csv in $raw.outputs | Where-Object kind -eq 'csv') { $csv.file = "test-$($csv.sourceFile)" }
        }
        $configurationPath = Join-Path $fixture.Root 'catalog-manifest.json'
        Save-CatalogJson -Path $configurationPath -Data $raw
        $configuration = Read-AvmCatalogConfiguration -Path $configurationPath
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture -Configuration $configuration
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
        [System.IO.File]::ReadAllText((Join-Path $fixture.Legacy 'test-BicepResourceModules.csv')) | Should -BeExactly 'not a source CSV'
        [System.IO.File]::Delete((Join-Path $fixture.Modules[0].Directory 'metadata.json'))
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture -Configuration $configuration
        (Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory).HeldBackSourceFiles |
            Should -Contain 'BicepResourceModules.csv'
    }

    It 'does not treat a corrected repository URL or non-identity field as a removal' {
        $fixture = New-CatalogFixture -AdoptAll
        $file = 'TerraformResourceModules.csv'
        $row = $fixture.Original[$file]
        $row.RepoURL += '/'
        $row.Description = 'Changed source description'
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($row)))
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
        @($bundle.Files["docs/$file"] | ConvertFrom-Csv)[0].RepoURL | Should -BeExactly $fixture.Modules[3].Identity.RepoURL
    }

    It 'does not allow force to bypass duplicate source identities or legacy catalog records' {
        $fixture = New-CatalogFixture -AdoptAll
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture
        $inventory.Items[0].Record.metadataSource = 'legacy'
        { Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory -Force } | Should -Throw
        $file = 'BicepResourceModules.csv'
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $fixture.Original[$file])))
        { Get-CatalogFixtureBundle -Fixture $fixture -Force } | Should -Throw '*Duplicate legacy identity*'
    }
}

Describe 'Component: module catalog lifecycle and flat owners' -Tag Component {
    It 'deprecates a Bicep <Scope> and descendants but not unrelated modules' -TestCases @(
        @{ Scope = 'root' }
        @{ Scope = 'child' }
    ) {
        param($Scope)
        $fixture = New-CatalogFixture -AdoptAll
        $child = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/blob-service' -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/blob-service/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/file-service' -Canonical 'Microsoft.Storage/storageAccounts/fileServices' -Child -Adopt
        $markerRoot = if ($Scope -eq 'root') { $fixture.Modules[0].Directory } else { $child.Directory }
        [System.IO.File]::WriteAllText((Join-Path $markerRoot 'DEPRECATED.md'), 'Use the replacement module.')
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $rows = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)
        foreach ($row in $rows) {
            $expected = if ($Scope -eq 'root' -or $row.ModuleName -like '*blob-service*') { 'Deprecated' } else { 'Available' }
            $row.ModuleStatus | Should -Be $expected
            $bundle.Catalog.modules["$($row.ProviderNamespace)/$($row.ResourceType)"].bicep[0].moduleStatus | Should -Be $expected
        }
        $bundle.Catalog.modules['lz/sub-vending'].bicep[0].moduleStatus | Should -Be 'Available'
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].terraform[0].moduleStatus | Should -Be 'Available'
    }

    It 'retains Bicep deprecation evidence in the source snapshot and offline output' {
        $fixture = New-CatalogFixture -AdoptAll
        $marker = Join-Path $fixture.Modules[0].Directory 'DEPRECATED.md'
        [System.IO.File]::WriteAllText($marker, 'Retired module.')
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture
        $snapshot = Join-Path $fixture.Root 'snapshot'
        $copy = Join-Path $snapshot 'sources' 'bicep'
        Copy-AvmCatalogBicepSource -Sources @($inventory.Sources | Where-Object Ecosystem -eq 'bicep') -Destination $copy
        [System.IO.File]::ReadAllText((Join-Path $copy 'avm' 'res' 'storage' 'storage-account' 'DEPRECATED.md')) |
            Should -BeExactly 'Retired module.'
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        Copy-Item -LiteralPath $fixture.Terraform -Destination (Join-Path $snapshot 'sources' 'terraform') -Recurse
        Copy-Item -LiteralPath $fixture.Legacy -Destination (Join-Path $snapshot 'legacy') -Recurse
        foreach ($file in @('registry.json', 'github.json', 'revisions.json')) {
            Copy-Item -LiteralPath (Join-Path $fixture.Root $file) -Destination (Join-Path $snapshot $file)
        }
        & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $snapshot -OutputPath $fixture.Output | Out-Null
        $catalog = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'docs' 'v1' 'modules.json')
        $catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].moduleStatus | Should -Be 'Deprecated'
    }

    It 'rejects ambiguous deprecation marker <Shape>' -TestCases @(
        @{ Shape = 'casing' }
        @{ Shape = 'directory' }
    ) {
        param($Shape)
        $fixture = New-CatalogFixture -AdoptAll
        if ($Shape -eq 'casing') {
            [System.IO.File]::WriteAllText((Join-Path $fixture.Modules[0].Directory 'Deprecated.md'), 'wrong casing')
        }
        else {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Modules[0].Directory 'DEPRECATED.md')
        }
        { Get-CatalogFixtureBundle -Fixture $fixture } | Should -Throw '*regular file named DEPRECATED.md*'
    }

    It 'deprecates all Terraform implementations in an archived repository, even without owners' {
        $fixture = New-CatalogFixture -AdoptAll
        $repository = 'Azure/terraform-azurerm-avm-res-storage-storageaccount'
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository $repository `
            -ModulePath 'modules/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
        $metadataPath = Join-Path $fixture.Modules[3].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $metadataPath
        $metadata.owners = @()
        Save-CatalogJson -Path $metadataPath -Data $metadata
        $fixture.Archived[$repository] = $true
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        # Terraform submodule rows are excluded from the CSV, so only the root row is expected.
        $rows = @($bundle.Files['docs/TerraformResourceModules.csv'] | ConvertFrom-Csv)
        $rows | Should -HaveCount 1
        foreach ($row in $rows) {
            $row.ModuleStatus | Should -Be 'Deprecated'
            $bundle.Catalog.modules["$($row.ProviderNamespace)/$($row.ResourceType)"].terraform[0].moduleStatus | Should -Be 'Deprecated'
        }
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts/blobServices/containers'].terraform[0].moduleStatus | Should -Be 'Deprecated'
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].moduleStatus | Should -Be 'Available'
    }

    Context 'deprecated exclusions' {
        It 'excludes the only <Ecosystem> <ModuleType> row and canonical entry with a publishable warning' -TestCases @(
            foreach ($ecosystem in @('bicep', 'terraform')) {
                foreach ($kind in @('resource', 'pattern', 'utility')) {
                    @{ Ecosystem = $ecosystem; ModuleType = $kind }
                }
            }
        ) {
            param($Ecosystem, $ModuleType)
            $fixture = New-CatalogFixture -AdoptAll
            $module = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq $ModuleType })[0]
            $module.Canonical = if ($ModuleType -eq 'resource') { 'Microsoft.Example/unusedModules' } else { 'unused-module' }
            Save-CatalogMetadata -Module $module
            if ($Ecosystem -eq 'bicep') {
                [System.IO.File]::WriteAllText((Join-Path $module.Directory 'DEPRECATED.md'), 'Deprecated.')
            }
            else {
                $fixture.Archived[$module.Repository] = $true
            }
            $metadataHash = (Get-FileHash -LiteralPath (Join-Path $module.Directory 'metadata.json')).Hash
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $module.Identity.Key -WarningAction SilentlyContinue
            $sourceRoot = Initialize-CatalogPublicationBase -Fixture $fixture
            $diagnostics = Join-Path $fixture.Root 'diagnostics'
            & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output `
                -DiagnosticsPath $diagnostics -WarningVariable warnings | Out-Null

            @($warnings) | Should -HaveCount 1
            $warnings[0].Message | Should -BeLike "*Omitted deprecated, unpublished module $($module.Repository) (module path '$($module.ModulePath)')*Consider deleting*"
            if ($Ecosystem -eq 'terraform') {
                $warnings[0].Message | Should -BeLike '*unused repository if it contains no published modules*'
            }
            else {
                $warnings[0].Message | Should -BeLike '*module''s source, preserving any published descendants*'
            }
            $catalog = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'docs' 'v1' 'modules.json')
            $catalog.modules.Contains($module.Canonical) | Should -BeFalse
            $remaining = @($catalog.modules.Values | ForEach-Object { $_.bicep; $_.terraform })
            $remaining | Should -HaveCount 5
            foreach ($record in $remaining) { $record.moduleStatus | Should -BeExactly 'Available' }
            $output = @($bundle.Configuration.outputs | Where-Object {
                    $_.kind -eq 'csv' -and $_.ecosystem -eq $Ecosystem -and $_.moduleType -eq $ModuleType
                })[0]
            @(Import-Csv -LiteralPath (Join-Path $fixture.Output $output.bundlePath)) | Should -HaveCount 0
            $report = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'v1' 'migration-report.json')
            $report.counts.catalogEntries | Should -Be 5
            $report.counts.adoptedEntries | Should -Be 6
            $report.counts.excludedEntries | Should -Be 1
            $report.excludedModules[0].repository | Should -BeExactly $module.Repository
            $report.excludedModules[0].modulePath | Should -BeExactly $module.ModulePath
            $report.excludedModules[0].registry.status | Should -BeExactly 'not-published'
            $report.sourceCsvRows[$output.sourceFile] | Should -HaveCount 1
            $report.counts.csvRows[$output.sourceFile] | Should -Be 0
            $report.parity.bicepOnly | Should -Not -Contain $module.Canonical
            $report.parity.terraformOnly | Should -Not -Contain $module.Canonical
            $report.csvRowRemovals | Should -HaveCount 0
            $report.csvRowRemovalsForced | Should -BeFalse
            $report.heldBackOutputs | Should -HaveCount 0
            $mar = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'docs' 'BicepMARModules.json')
            $originalMar = Read-AvmCatalogJson -Path (Join-Path $fixture.Legacy 'BicepMARModules.json')
            $mar | Should -Be (Get-AvmCatalogOrdinal -Values $originalMar)
            (Get-FileHash -LiteralPath (Join-Path $module.Directory 'metadata.json')).Hash | Should -BeExactly $metadataHash
            $plan = Test-AvmCatalogPublicationBundle -Path $fixture.Output
            { Assert-AvmCatalogPublicationBase -Root $sourceRoot -BaseFiles $plan.docs.baseFiles } | Should -Not -Throw
            (Get-AvmCatalogPublicationRowRemovals -BundlePath $fixture.Output -Configuration $bundle.Configuration -SourceRoot $sourceRoot) |
                Should -HaveCount 0
            & (Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1') -BundlePath $fixture.Output |
                Should -BeExactly 'Catalog publication plan validated; no remote changes requested.'
            { & (Join-Path $catalogScripts 'Assert-ModuleCatalogPublication.ps1') -DiagnosticsPath $diagnostics } | Should -Not -Throw
        }

        It 'preserves published Bicep <Published> when the <Scope> is deprecated' -TestCases @(
            foreach ($scope in @('root', 'child')) {
                foreach ($published in @('root', 'child', 'grandchild')) {
                    @{ Scope = $scope; Published = $published }
                }
            }
        ) {
            param($Scope, $Published)
            $fixture = New-CatalogFixture -AdoptAll
            $family = @{
                root = $fixture.Modules[0]
                child = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
                    -ModulePath 'avm/res/storage/storage-account/blob-service' -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
                grandchild = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
                    -ModulePath 'avm/res/storage/storage-account/blob-service/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
                sibling = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
                    -ModulePath 'avm/res/storage/storage-account/file-service' -Canonical 'Microsoft.Storage/storageAccounts/fileServices' -Child -Adopt
                helper = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
                    -ModulePath 'avm/res/storage/storage-account/blob-service/helper' -Canonical 'helper' -Child -Adopt
            }
            [System.IO.File]::WriteAllText((Join-Path $family[$Scope].Directory 'DEPRECATED.md'), 'Deprecated.')
            $file = 'BicepResourceModules.csv'
            $sourceRows = @($fixture.Original[$file]) + @(foreach ($name in @('child', 'grandchild', 'sibling')) {
                    $row = [ordered]@{}
                    foreach ($header in $fixture.Headers[$file]) { $row[$header] = $fixture.Original[$file][$header] }
                    $row.ModuleName = $family[$name].Identity.ModuleName
                    $row.RepoURL = $family[$name].Identity.RepoURL
                    $row
                })
            [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
                (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows $sourceRows))
            $unpublished = @($family.Keys | Where-Object { $_ -ne $Published } | ForEach-Object { $family[$_].Identity.Key })
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $unpublished -WarningVariable warnings
            $records = @($bundle.Catalog.modules.Values.bicep)
            $rows = @($bundle.Files["docs/$file"] | ConvertFrom-Csv)
            $expectedExclusions = 0
            foreach ($name in $family.Keys) {
                $module = $family[$name]
                $deprecated = $Scope -eq 'root' -or $name -in @('child', 'grandchild', 'helper')
                $excluded = $deprecated -and $name -ne $Published
                $found = @($records | Where-Object modulePath -CEQ $module.ModulePath)
                $row = @($rows | Where-Object ModuleName -CEQ $module.Identity.ModuleName)
                if ($excluded) {
                    $expectedExclusions++
                    $found | Should -HaveCount 0
                    $row | Should -HaveCount 0
                    $warnings.Message -join "`n" | Should -BeLike "*module path '$($module.ModulePath)'*"
                }
                else {
                    $found | Should -HaveCount 1
                    $expected = if ($deprecated) { 'Deprecated' } elseif ($name -eq $Published) { 'Available' } else { 'Proposed' }
                    $found[0].moduleStatus | Should -BeExactly $expected
                    Get-CatalogOwnerHandles $found[0].owners | Should -Be @('owner-one', 'owner-two', 'owner-three', '@Azure/avm-core-modules')
                    $row[0].ModuleStatus | Should -BeExactly $expected
                }
            }
            $bundle.Report.excludedModules | Should -HaveCount $expectedExclusions
            $bundle.Catalog.modules.Contains('helper') | Should -BeFalse
            $bundle.Report.csvRowRemovals | Should -HaveCount 0
            $bundle.HeldBack | Should -HaveCount 0
            $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].terraform[0].moduleStatus | Should -BeExactly 'Available'
        }

        It 'preserves an archived Terraform published <Published> while excluding its unpublished family members' -TestCases @(
            @{ Published = 'root' }
            @{ Published = 'child' }
        ) {
            param($Published)
            $fixture = New-CatalogFixture -AdoptAll
            $root = $fixture.Modules[3]
            $family = @{
                root = $root
                child = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository $root.Repository `
                    -ModulePath 'modules/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
                unused = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository $root.Repository `
                    -ModulePath 'modules/unused' -Canonical 'Microsoft.Storage/storageAccounts/fileServices' -Child -Adopt
                helper = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository $root.Repository `
                    -ModulePath 'modules/helper' -Canonical 'helper' -Child -Adopt
            }
            $fixture.Archived[$root.Repository] = $true
            $file = 'TerraformResourceModules.csv'
            $childRow = [ordered]@{}
            foreach ($header in $fixture.Headers[$file]) { $childRow[$header] = $fixture.Original[$file][$header] }
            $childRow.ModuleName = $family.unused.Identity.ModuleName
            $childRow.RepoURL = $family.unused.Identity.RepoURL
            [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
                (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $childRow)))
            $unpublished = @($family.Keys | Where-Object { $_ -ne $Published } | ForEach-Object { $family[$_].Identity.Key })
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $unpublished -WarningVariable warnings
            $records = @($bundle.Catalog.modules.Values.terraform | Where-Object repository -CEQ $root.Repository)
            $records | Should -HaveCount 1
            $records[0].modulePath | Should -BeExactly $family[$Published].ModulePath
            $records[0].moduleStatus | Should -BeExactly 'Deprecated'
            $records[0].owners | Should -HaveCount 4
            $bundle.Report.excludedModules | Should -HaveCount 3
            $bundle.Catalog.modules.Contains('helper') | Should -BeFalse
            $bundle.Report.csvRowRemovals | Should -HaveCount 0
            $bundle.HeldBack | Should -HaveCount 0
            @($bundle.Files["docs/$file"] | ConvertFrom-Csv) | Should -HaveCount $(if ($Published -eq 'root') { 1 } else { 0 })
            @($warnings | Where-Object Message -like "*module path 'modules/unused'*")[0].Message |
                Should -BeLike '*Consider deleting this unused module''s source*'
        }

        It 'excludes deprecated metadata-only <Ecosystem> scaffolds without relaxing the published-source guard' -TestCases @(
            @{ Ecosystem = 'bicep' }
            @{ Ecosystem = 'terraform' }
        ) {
            param($Ecosystem)
            $fixture = New-CatalogFixture -AdoptAll
            $repository = if ($Ecosystem -eq 'bicep') { 'Azure/bicep-registry-modules' } else { 'Azure/terraform-azurerm-avm-ptn-ai-ml-landing-zone' }
            $path = if ($Ecosystem -eq 'bicep') { 'avm/ptn/ai-ml/landing-zone' } else { '.' }
            $module = Add-CatalogModule -Fixture $fixture -Ecosystem $Ecosystem -Repository $repository `
                -ModulePath $path -Canonical 'ai-ml/landing-zone' -Adopt -SourcePending
            if ($Ecosystem -eq 'bicep') {
                [System.IO.File]::WriteAllText((Join-Path $module.Directory 'DEPRECATED.md'), 'Deprecated.')
            }
            else { $fixture.Archived[$repository] = $true }
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture
            $bundle.Catalog.modules.Contains('ai-ml/landing-zone') | Should -BeFalse
            $bundle.Report.excludedModules | Should -HaveCount 1
            $bundle.HeldBack | Should -HaveCount 0
            $registryPath = Join-Path $fixture.Root 'registry.json'
            $registry = Read-AvmCatalogJson -Path $registryPath
            $registry[$module.Identity.Key] = New-AvmCatalogRegistryResult -Version '1.0.0' -FirstPublished ([datetime]'2024-02-01') `
                -MarRegistered $(if ($Ecosystem -eq 'bicep') { $true } else { $null })
            Save-CatalogJson -Path $registryPath -Data $registry
            { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output -Force } |
                Should -Throw '*metadata but no source*registry reports it as available*'
            Test-Path -LiteralPath $fixture.Output | Should -BeFalse
        }

        It 'does not let an exclusion hide an unrelated <Case> removal' -TestCases @(
            @{ Case = 'missing metadata'; Ecosystem = 'bicep' }
            @{ Case = 'published helper'; Ecosystem = 'bicep' }
            @{ Case = 'unresolved identity'; Ecosystem = 'bicep' }
            @{ Case = 'same-name provider'; Ecosystem = 'terraform' }
            @{ Case = 'different CSV'; Ecosystem = 'bicep' }
        ) {
            param($Case, $Ecosystem)
            $fixture = New-CatalogFixture -AdoptAll
            $module = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq 'resource' })[0]
            if ($Ecosystem -eq 'bicep') {
                [System.IO.File]::WriteAllText((Join-Path $module.Directory 'DEPRECATED.md'), 'Deprecated.')
            }
            else { $fixture.Archived[$module.Repository] = $true }
            $file = if ($Ecosystem -eq 'bicep') { 'BicepResourceModules.csv' } else { 'TerraformResourceModules.csv' }
            if ($Case -eq 'different CSV') {
                $unrelated = $fixture.Modules[1]
                $heldFile = 'BicepPatternModules.csv'
                [System.IO.File]::Delete((Join-Path $unrelated.Directory 'metadata.json'))
            }
            else {
                $heldFile = $file
                $unrelated = switch ($Case) {
                    'missing metadata' {
                        Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository $module.Repository `
                            -ModulePath 'avm/res/key-vault/vault' -Canonical 'Microsoft.KeyVault/vaults'
                    }
                    'published helper' {
                        Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository $module.Repository `
                            -ModulePath "$($module.ModulePath)/helper" -Canonical 'helper' -Child -Adopt
                    }
                    'same-name provider' {
                        Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azure-avm-res-storage-storageaccount' `
                            -ModulePath '.' -Canonical $module.Canonical
                    }
                    'unresolved identity' {
                        @{ Identity = @{ ModuleName = 'unresolved-module'; RepoURL = 'not-a-repository' } }
                    }
                }
                $row = [ordered]@{}
                foreach ($header in $fixture.Headers[$file]) { $row[$header] = $fixture.Original[$file][$header] }
                $row.ModuleName = $unrelated.Identity.ModuleName
                $row.RepoURL = $unrelated.Identity.RepoURL
                [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
                    (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($fixture.Original[$file], $row)))
            }
            $null = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $module.Identity.Key
            $sourceRoot = Initialize-CatalogPublicationBase -Fixture $fixture
            $diagnostics = Join-Path $fixture.Root 'diagnostics'
            & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output -DiagnosticsPath $diagnostics | Out-Null
            $report = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'v1' 'migration-report.json')
            $report.excludedModules | Should -HaveCount 1
            $report.csvRowRemovals | Should -HaveCount 1
            $report.csvRowRemovals[0].moduleName | Should -BeExactly $unrelated.Identity.ModuleName
            $report.csvRowRemovals[0].repoURL | Should -BeExactly $unrelated.Identity.RepoURL
            $report.csvRowRemovalsForced | Should -BeFalse
            $report.heldBackSourceFiles | Should -Be @($heldFile)
            $report.heldBackOutputs | Should -Contain 'docs/v1/modules.json'
            if ($Case -eq 'different CSV') { $report.heldBackSourceFiles | Should -Not -Contain $file }
            $null = Test-AvmCatalogPublicationBundle -Path $fixture.Output
            $removals = Get-AvmCatalogPublicationRowRemovals -BundlePath $fixture.Output -Configuration (Read-AvmCatalogConfiguration) -SourceRoot $sourceRoot
            $removals | Should -HaveCount 1
            { Assert-AvmCatalogCsvRowRetention -Removals $removals } | Should -Throw '*CSV row removals are blocked*'
            { & (Join-Path $catalogScripts 'Assert-ModuleCatalogPublication.ps1') -DiagnosticsPath $diagnostics } | Should -Throw '*held back*'
        }

        It 'validates excluded modules before filtering despite <Case>' -TestCases @(
            @{ Case = 'invalid metadata'; Ecosystem = 'bicep'; File = 'metadata' }
            @{ Case = 'missing registry entry'; Ecosystem = 'bicep'; File = 'registry.json'; Change = { param($data, $key) $data.Remove($key) } }
            @{ Case = 'unpublished with version'; Ecosystem = 'bicep'; File = 'registry.json'; Change = { param($data, $key) $data[$key].currentVersion = '1.0.0' } }
            @{ Case = 'unpublished with date'; Ecosystem = 'bicep'; File = 'registry.json'; Change = { param($data, $key) $data[$key].firstPublishedIn = '2024-02' } }
            @{ Case = 'unpublished with downloads'; Ecosystem = 'terraform'; File = 'registry.json'; Change = { param($data, $key) $data[$key].downloads = 1 } }
            @{ Case = 'unknown registry status'; Ecosystem = 'terraform'; File = 'registry.json'; Change = { param($data, $key) $data[$key].status = 'unknown' } }
            @{ Case = 'invalid Bicep registration'; Ecosystem = 'bicep'; File = 'registry.json'; Change = { param($data, $key) $data[$key].marRegistered = $null } }
            @{ Case = 'invalid Terraform registration'; Ecosystem = 'terraform'; File = 'registry.json'; Change = { param($data, $key) $data[$key].marRegistered = $true } }
            @{ Case = 'missing owner evidence'; Ecosystem = 'bicep'; File = 'github.json'; Change = { param($data) $data.users.Remove('owner-one') } }
            @{ Case = 'missing archive flag'; Ecosystem = 'terraform'; File = 'revisions.json'; Change = {
                    param($data, $key)
                    @($data | Where-Object repository -EQ $key.Split(':')[1])[0].Remove('archived')
                } }
            @{ Case = 'unknown archive evidence'; Ecosystem = 'terraform'; File = 'revisions.json'; Change = {
                    param($data, $key)
                    $revision = @($data | Where-Object repository -EQ $key.Split(':')[1])[0]
                    $revision.archived = $null; $revision.status = 'not-found'; $revision.commit = $null
                } }
        ) {
            param($Ecosystem, $File, $Change)
            $fixture = New-CatalogFixture -AdoptAll
            $module = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq 'resource' })[0]
            if ($Ecosystem -eq 'bicep') {
                [System.IO.File]::WriteAllText((Join-Path $module.Directory 'DEPRECATED.md'), 'Deprecated.')
            }
            else { $fixture.Archived[$module.Repository] = $true }
            $null = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $module.Identity.Key
            if ($File -eq 'metadata') {
                [System.IO.File]::WriteAllText((Join-Path $module.Directory 'metadata.json'), '{}')
            }
            else {
                $path = Join-Path $fixture.Root $File
                $data = Read-AvmCatalogJson -Path $path
                & $Change $data $module.Identity.Key
                Save-CatalogJson -Path $path -Data $data
            }
            foreach ($force in @($false, $true)) {
                { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output -Force:$force } |
                    Should -Throw
                Test-Path -LiteralPath $fixture.Output | Should -BeFalse
            }
        }

        It 'does not hold back an excluded module solely for an owner who no longer exists' {
            $fixture = New-CatalogFixture -AdoptAll
            $module = $fixture.Modules[0]
            $path = Join-Path $module.Directory 'metadata.json'
            $metadata = Read-AvmCatalogJson -Path $path
            $metadata.owners = @('owner-gone')
            Save-CatalogJson -Path $path -Data $metadata
            [System.IO.File]::WriteAllText((Join-Path $module.Directory 'DEPRECATED.md'), 'Deprecated.')
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $module.Identity.Key -MissingOwner 'owner-gone'
            $bundle.Report.excludedModules | Should -HaveCount 1
            $bundle.Report.missingOwners | Should -HaveCount 0
            $bundle.HeldBack | Should -HaveCount 0
        }
    }

    It 'resolves Bicep <Case> publication independently of the rest of the family' -TestCases @(
        @{ Case = 'child-ahead-of-root'; Published = @('avm/res/storage/storage-account/blob-service') }
        @{ Case = 'root-ahead-of-child'; Published = @('avm/res/storage/storage-account') }
        @{ Case = 'grandchild-only'; Published = @('avm/res/storage/storage-account/blob-service/container') }
    ) {
        param($Case, $Published)
        $fixture = New-CatalogFixture -AdoptAll
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/blob-service' -Canonical 'Microsoft.Storage/storageAccounts/blobServices' -Child -Adopt
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/storage/storage-account/blob-service/container' -Canonical 'Microsoft.Storage/storageAccounts/blobServices/containers' -Child -Adopt
        $inventory = Get-CatalogFixtureInventory -Fixture $fixture
        $registry = [ordered]@{}
        foreach ($item in $inventory.Items) {
            $isBicep = $item.Identity.Ecosystem -eq 'bicep'
            $live = -not $isBicep -or $Published -ccontains $item.Identity.ModulePath
            $registry[$item.Identity.Key] = [ordered]@{
                status = if ($live) { 'available' } else { 'not-published' }
                currentVersion = if ($live) { '1.2.3' } else { $null }
                firstPublishedIn = if ($live) { '2024-02' } else { $null }
                downloads = $null
                marRegistered = if ($isBicep) { $true } else { $null }
            }
        }
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
            }
        }
        $revisions = @(
            foreach ($repository in @($inventory.Items | Where-Object { $_.Identity.Ecosystem -eq 'terraform' } |
                    ForEach-Object { $_.Identity.Repository } | Sort-Object -Unique)) {
                [ordered]@{ repository = $repository; commit = 'a' * 40; status = 'collected'; archived = $false }
            }
        )
        $bundle = New-AvmCatalogBundle -Inventory $inventory -Registry $registry -GitHub $github -RepositoryRevisions $revisions
        $rows = @{}
        foreach ($row in @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)) {
            $rows[$row.ModuleName] = $row
        }
        foreach ($path in @('avm/res/storage/storage-account', 'avm/res/storage/storage-account/blob-service',
                'avm/res/storage/storage-account/blob-service/container')) {
            $expected = if ($Published -ccontains $path) { 'Available' } else { 'Proposed' }
            $record = @($bundle.Catalog.modules.Values.bicep | Where-Object { $_.modulePath -ceq $path })[0]
            $record.moduleStatus | Should -BeExactly $expected
            $record.registry.status | Should -BeExactly $(if ($expected -eq 'Available') { 'available' } else { 'not-published' })
            $rows[$path].ModuleStatus | Should -BeExactly $expected
            $rows[$path].FirstPublishedIn | Should -BeExactly $(if ($expected -eq 'Available') { '2024-02' } else { '' })
        }
    }

    It 'requires the removal override for deprecated <Ecosystem> source rows without metadata' -TestCases @(
        @{ Ecosystem = 'bicep'; File = 'BicepResourceModules.csv' }
        @{ Ecosystem = 'terraform'; File = 'TerraformResourceModules.csv' }
    ) {
        param($Ecosystem, $File)
        $fixture = New-CatalogFixture -AdoptAll
        $module = @($fixture.Modules | Where-Object { $_.Ecosystem -eq $Ecosystem -and $_.ModuleType -eq 'resource' })[0]
        [System.IO.File]::Delete((Join-Path $module.Directory 'metadata.json'))
        if ($Ecosystem -eq 'bicep') {
            [System.IO.File]::WriteAllText((Join-Path $fixture.Modules[0].Directory 'DEPRECATED.md'), 'Deprecated.')
        }
        else {
            $fixture.Archived['Azure/terraform-azurerm-avm-res-storage-storageaccount'] = $true
        }
        (Get-CatalogFixtureBundle -Fixture $fixture).HeldBackSourceFiles | Should -Contain $File
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Force
        @($bundle.Files["docs/$File"] | ConvertFrom-Csv) | Should -HaveCount 0
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'][$Ecosystem] | Should -HaveCount 0
        $bundle.Report.csvRowRemovals | Should -HaveCount 1
        $bundle.Report.csvRowRemovals[0].sourceFile | Should -BeExactly $File
    }

    It 'fails offline generation for an incomplete archive snapshot instead of treating repositories as active' {
        $fixture = New-CatalogFixture -AdoptAll
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        Save-CatalogJson -Path (Join-Path $fixture.Root 'revisions.json') -Data @()
        { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output } |
            Should -Throw '*archive snapshot is incomplete*'
        Test-Path $fixture.Output | Should -BeFalse
    }

    It 'keeps users out of team columns and teams out of user columns while retaining all JSON owners' {
        $fixture = New-CatalogFixture -AdoptAll
        $metadataPath = Join-Path $fixture.Modules[0].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $metadataPath
        $metadata.owners = @('@Azure/avm-core-modules', 'owner-three', '@Azure/second-team', 'owner-one', 'owner-two')
        Save-CatalogJson -Path $metadataPath -Data $metadata
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $row = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
        $row.PrimaryModuleOwnerGHHandle | Should -BeExactly 'owner-three'
        $row.PrimaryModuleOwnerDisplayName | Should -BeExactly ''
        $row.SecondaryModuleOwnerGHHandle | Should -BeExactly 'owner-one'
        $row.SecondaryModuleOwnerDisplayName | Should -BeExactly 'Profile One'
        $row.ModuleOwnersGHTeam | Should -BeExactly '@Azure/avm-core-modules'
        Get-CatalogOwnerHandles $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].owners |
            Should -Be $metadata.owners
    }

    It 'holds back only the CSV that names a GitHub owner who no longer exists' {
        $fixture = New-CatalogFixture -AdoptAll
        $metadataPath = Join-Path $fixture.Modules[0].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $metadataPath
        $metadata.owners = @('owner-gone', 'owner-two')
        Save-CatalogJson -Path $metadataPath -Data $metadata
        $diagnostics = Join-Path $fixture.Root 'diagnostics'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -MissingOwner 'owner-gone' -DiagnosticsPath $diagnostics
        $bundle.HeldBackSourceFiles | Should -Be @('BicepResourceModules.csv')
        $bundle.HeldBack | Should -Contain 'docs/v1/modules.json'
        $bundle.HeldBack | Should -Not -Contain 'docs/BicepPatternModules.csv'
        $bundle.Report.missingOwners | Should -HaveCount 1
        $bundle.Report.missingOwners[0].moduleName | Should -BeExactly $fixture.Modules[0].Identity.ModuleName
        $bundle.Report.missingOwners[0].owners | Should -Be @('owner-gone')
        $row = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
        $row.PrimaryModuleOwnerGHHandle | Should -BeExactly 'owner-gone'
        $row.PrimaryModuleOwnerDisplayName | Should -BeExactly ''
        $row.SecondaryModuleOwnerDisplayName | Should -BeExactly 'Profile Two'
        $report = Read-AvmCatalogJson -Path (Join-Path $diagnostics 'missing-owners.json')
        $report.missingOwnerCount | Should -Be 1
        $report.missingOwners[0].sourceFile | Should -BeExactly 'BicepResourceModules.csv'
        ([System.IO.File]::ReadAllText((Join-Path $diagnostics 'missing-owners.csv')) -split "`n")[0] |
            Should -BeExactly 'SourceFile,ModuleName,RepoURL,MissingOwners,Published'
    }

    It 'publishes every CSV with force even when a GitHub owner no longer exists' {
        $fixture = New-CatalogFixture -AdoptAll
        $metadataPath = Join-Path $fixture.Modules[0].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $metadataPath
        $metadata.owners = @('owner-gone', '@Azure/team-gone')
        Save-CatalogJson -Path $metadataPath -Data $metadata
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -MissingOwner @('owner-gone', '@Azure/team-gone') -Force
        $bundle.HeldBack | Should -HaveCount 0
        $bundle.Report.missingOwners | Should -HaveCount 1
        $bundle.Report.missingOwners[0].owners | Should -Be @('owner-gone', '@Azure/team-gone')
        $row = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
        $row.ModuleOwnersGHTeam | Should -BeExactly '@Azure/team-gone'
    }

    It 'rejects incomplete or ambiguous archive evidence: <Case>' -TestCases @(
        @{ Case = 'missing flag'; Records = @(@{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; commit = 'a' * 40; status = 'collected' }) }
        @{ Case = 'text flag'; Records = @(@{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; commit = 'a' * 40; status = 'collected'; archived = 'false' }) }
        @{ Case = 'unknown collected flag'; Records = @(@{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; commit = 'a' * 40; status = 'collected'; archived = $null }) }
        @{ Case = 'missing commit'; Records = @(@{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; status = 'collected'; archived = $false }) }
        @{ Case = 'unavailable with false flag'; Records = @(@{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; commit = $null; status = 'not-found'; archived = $false }) }
        @{ Case = 'duplicate revision'; Records = @(
                @{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; commit = 'a' * 40; status = 'collected'; archived = $true }
                @{ repository = 'Azure/terraform-azurerm-avm-res-test-module'; commit = 'a' * 40; status = 'collected'; archived = $false }
            ) }
    ) {
        param($Records)
        { Get-AvmCatalogArchivedRepositories -RepositoryRevisions $Records } | Should -Throw
    }
}
