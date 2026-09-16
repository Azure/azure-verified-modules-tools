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
            [string] $ModulePath, [string] $Canonical, [switch] $Child, [switch] $Adopt
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
        [System.IO.File]::WriteAllText((Join-Path $directory $name), $source)
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
        param([object] $Fixture, [string] $BicepMode = 'dual-source', [string] $TerraformMode = 'dual-source')
        Get-AvmCatalogInventory -BicepRoot $Fixture.Bicep -TerraformRoot $Fixture.Terraform -LegacyPath $Fixture.Legacy `
            -BicepMode $BicepMode -TerraformMode $TerraformMode
    }

    function Get-CatalogFixtureBundle {
        param([object] $Fixture, [object] $Inventory)
        if ($null -eq $Inventory) {
            $Inventory = Get-CatalogFixtureInventory -Fixture $Fixture
        }
        $registry = [ordered]@{}
        foreach ($item in $Inventory.Items) {
            $registry[$item.Identity.Key] = [ordered]@{
                status = 'available'; currentVersion = '1.2.3'; firstPublishedIn = '2024-02'
                downloads = if ($item.Identity.Ecosystem -eq 'terraform' -and $item.Identity.ModulePath -eq '.') { 123 } else { $null }
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
                '@Azure/avm-core-modules' = @{ slug = 'avm-core-modules'; organization = 'Azure' }
                '@Azure/second-team' = @{ slug = 'second-team'; organization = 'Azure' }
            }
        }
        Save-CatalogJson -Path (Join-Path $Fixture.Root 'registry.json') -Data $registry
        Save-CatalogJson -Path (Join-Path $Fixture.Root 'github.json') -Data $github
        Save-CatalogJson -Path (Join-Path $Fixture.Root 'revisions.json') -Data $revisions
        return New-AvmCatalogBundle -Inventory $Inventory -Registry $registry -GitHub $github -RepositoryRevisions $revisions
    }
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: module catalog transformations' -Tag Component {
    It 'preserves all six legacy headers, order and values while appending canonical identity only' {
        $fixture = New-CatalogFixture
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        foreach ($file in $fixture.Original.Keys) {
            $text = $bundle.Files["docs/test-$file"]
            ($text -split "`n")[0] | Should -BeExactly (($fixture.Headers[$file] + @('CanonicalType')) -join ',')
            $row = @($text | ConvertFrom-Csv)[0]
            foreach ($column in $fixture.Headers[$file]) {
                $row.$column | Should -BeExactly $fixture.Original[$file][$column] -Because "$file $column is not adopted"
            }
        }
        $bundle.Report.missingMetadata.Count | Should -Be 6
        $bundle.Report.unresolvedLegacy.Count | Should -Be 2
        $bundle.Files['docs/BicepMARModules.json'] | ConvertFrom-Json | Should -HaveCount 3
    }

    It 'uses metadata per adopted module and resolves only the first two names from the profile cache' {
        $fixture = New-CatalogFixture
        Save-CatalogMetadata -Module $fixture.Modules[0]
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $row = @($bundle.Files['docs/test-BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
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
        ($publishedOwners -join ',') | Should -BeExactly 'owner-one,owner-two,owner-three,@Azure/avm-core-modules'
        @($bundle.Files['docs/test-TerraformResourceModules.csv'] | ConvertFrom-Csv)[0].ModuleDisplayName | Should -BeExactly 'Legacy name'
    }

    It 'does not fall back or write outputs for invalid present metadata: <Kind>' -TestCases @(
        @{ Kind = 'json' }, @{ Kind = 'schema' }, @{ Kind = 'source' }, @{ Kind = 'bom' }
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
            'source' {
                $metadata = Read-AvmCatalogJson -Path $path
                $metadata.moduleDisplayName = 'Mismatched literal'
                Save-CatalogJson -Path $path -Data $metadata
            }
            'bom' {
                [System.IO.File]::WriteAllText($path, [System.IO.File]::ReadAllText($path), [System.Text.UTF8Encoding]::new($true))
            }
        }
        { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output } | Should -Throw '*Invalid present metadata*'
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
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
        $row = @($bundle.Files['docs/test-TerraformResourceModules.csv'] | ConvertFrom-Csv | Where-Object { $_.ModuleName -like '*//modules/*' })[0]
        $row.ParentModule | Should -BeExactly 'avm-res-storage-storageaccount'
        $row.PrimaryModuleOwnerGHHandle | Should -BeExactly 'owner-one'
        $row.SecondaryModuleOwnerGHHandle | Should -BeExactly 'owner-two'
        foreach ($file in @('BicepResourceModules.csv', 'TerraformResourceModules.csv')) {
            $childRows = @($bundle.Files["docs/test-$file"] | ConvertFrom-Csv | Where-Object { $_.ParentModule -ne 'n/a' })
            $childRows | Should -Not -BeNullOrEmpty
            foreach ($childRow in $childRows) {
                $childRow.AlternativeNames | Should -BeExactly ''
                $childRow.Comments | Should -BeExactly ''
            }
        }
        $published = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
        foreach ($canonical in @('Microsoft.Storage/storageAccounts', 'Microsoft.Storage/storageAccounts/blobServices/containers')) {
            foreach ($ecosystem in @('bicep', 'terraform')) {
                $publishedOwners = @($published.modules[$canonical][$ecosystem][0].owners)
                ($publishedOwners -join ',') | Should -BeExactly 'owner-one,owner-two,owner-three,@Azure/avm-core-modules'
            }
        }
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

        foreach ($mode in @('dual-source', 'metadata-only')) {
            $inventory = Get-CatalogFixtureInventory -Fixture $fixture -BicepMode $mode -TerraformMode $mode
            $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory
            $childRows = @($bundle.Files["docs/test-$file"] | ConvertFrom-Csv | Where-Object { $_.ModuleName -ceq $child.Identity.ModuleName })
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
        $record.owners | Should -Be @('@Azure/avm-core-modules')
        $record.telemetryIdPrefix | Should -BeNullOrEmpty
        $row = @($bundle.Files['docs/test-BicepUtilityModules.csv'] | ConvertFrom-Csv)[0]
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
        $record.owners | Should -Be @('owner-one')
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
        @($bundle.Files['docs/test-TerraformResourceModules.csv'] | ConvertFrom-Csv) | Should -HaveCount 2
    }

    It 'reports unmatched canonical types and unresolved Terraform taxonomy without inventing mappings' {
        $fixture = New-CatalogFixture
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Report.parity.bicepOnly | Should -Contain 'lz/sub-vending'
        $bundle.Report.parity.bicepOnly | Should -Contain 'types/common'
        $bundle.Report.unresolvedLegacy.moduleName | Should -Contain 'avm-ptn-lz-sub-vending'
        @($bundle.Files['docs/test-TerraformPatternModules.csv'] | ConvertFrom-Csv)[0].CanonicalType | Should -BeExactly ''
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository 'Azure/terraform-azapi-avm-res-compute-disk' `
            -ModulePath '.' -Canonical 'Microsoft.Compute/disks' -Adopt
        (Get-CatalogFixtureBundle -Fixture $fixture).Report.parity.terraformOnly | Should -Contain 'Microsoft.Compute/disks'
    }

    It 'supports independent metadata-only cutover and rejects missing or unresolved entries in the strict ecosystem' {
        $fixture = New-CatalogFixture
        { Get-CatalogFixtureInventory -Fixture $fixture -BicepMode metadata-only } | Should -Throw '*Metadata-only mode*'
        foreach ($module in @($fixture.Modules | Where-Object { $_.Ecosystem -eq 'bicep' })) {
            Save-CatalogMetadata -Module $module
        }
        { Get-CatalogFixtureInventory -Fixture $fixture -BicepMode metadata-only } | Should -Not -Throw
        { Get-CatalogFixtureInventory -Fixture $fixture -TerraformMode metadata-only } | Should -Throw '*Metadata-only mode*'
    }

    It 'does not read or publish repository configuration or generate tier metadata' {
        $fixture = New-CatalogFixture -AdoptAll
        $configurationPath = Join-Path $fixture.Root 'repository-config.json'
        [System.IO.File]::WriteAllText($configurationPath, 'not a catalog input')
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Files.Count | Should -Be 9
        @($bundle.Files.Keys | Where-Object { $_ -notlike 'docs/*' }) | Should -HaveCount 0
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
        $text = (Get-CatalogFixtureBundle -Fixture $fixture).Files["docs/test-$file"]
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
            @($bundle.Files["docs/test-$file"] | ConvertFrom-Csv) | Should -HaveCount 0
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

    It 'calculates an orphaned catalog status without overwriting an unmigrated legacy row' {
        $fixture = New-CatalogFixture
        $file = 'BicepResourceModules.csv'
        $row = $fixture.Original[$file]
        $row.PrimaryModuleOwnerGHHandle = ''
        $row.SecondaryModuleOwnerGHHandle = ''
        $row.ModuleOwnersGHTeam = ''
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($row)))
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].moduleStatus | Should -BeExactly 'Orphaned'
        ($bundle.Files["docs/test-$file"] | ConvertFrom-Csv).ModuleStatus | Should -BeExactly 'Proposed'
    }

    It 'reports unowned metadata as Orphaned but preserves existing Deprecated status in CSV and JSON' -TestCases @(
        @{ Previous = 'Available'; Expected = 'Orphaned' }
        @{ Previous = 'Deprecated'; Expected = 'Deprecated' }
    ) {
        param($Previous, $Expected)
        $fixture = New-CatalogFixture -AdoptAll
        $file = 'BicepResourceModules.csv'
        $row = $fixture.Original[$file]
        $row.ModuleStatus = $Previous
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($row)))
        $path = Join-Path $fixture.Modules[0].Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $path
        $metadata.owners = @()
        Save-CatalogJson -Path $path -Data $metadata
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].moduleStatus | Should -BeExactly $Expected
        ($bundle.Files["docs/test-$file"] | ConvertFrom-Csv).ModuleStatus | Should -BeExactly $Expected
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
        $rows = @($bundle.Files['docs/test-BicepResourceModules.csv'] | ConvertFrom-Csv)
        foreach ($row in $rows) {
            $expected = if ($Scope -eq 'root' -or $row.ModuleName -like '*blob-service*') { 'Deprecated' } else { 'Available' }
            $row.ModuleStatus | Should -Be $expected
            $bundle.Catalog.modules[$row.CanonicalType].bicep[0].moduleStatus | Should -Be $expected
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
        $rows = @($bundle.Files['docs/test-TerraformResourceModules.csv'] | ConvertFrom-Csv)
        $rows | Should -HaveCount 2
        foreach ($row in $rows) {
            $row.ModuleStatus | Should -Be 'Deprecated'
            $bundle.Catalog.modules[$row.CanonicalType].terraform[0].moduleStatus | Should -Be 'Deprecated'
        }
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].moduleStatus | Should -Be 'Available'
    }

    It 'derives Deprecated for legacy-only <Ecosystem> rows without rewriting their authored fields' -TestCases @(
        @{ Ecosystem = 'bicep'; File = 'BicepResourceModules.csv' }
        @{ Ecosystem = 'terraform'; File = 'TerraformResourceModules.csv' }
    ) {
        param($Ecosystem, $File)
        $fixture = New-CatalogFixture
        if ($Ecosystem -eq 'bicep') {
            [System.IO.File]::WriteAllText((Join-Path $fixture.Modules[0].Directory 'DEPRECATED.md'), 'Deprecated.')
        }
        else {
            $fixture.Archived['Azure/terraform-azurerm-avm-res-storage-storageaccount'] = $true
        }
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $row = @($bundle.Files["docs/test-$File"] | ConvertFrom-Csv)[0]
        $row.ModuleStatus | Should -Be 'Deprecated'
        $row.ModuleDisplayName | Should -Be $fixture.Original[$File].ModuleDisplayName
        $row.PrimaryModuleOwnerGHHandle | Should -Be $fixture.Original[$File].PrimaryModuleOwnerGHHandle
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'][$Ecosystem][0].moduleStatus | Should -Be 'Deprecated'
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
        $row = @($bundle.Files['docs/test-BicepResourceModules.csv'] | ConvertFrom-Csv)[0]
        $row.PrimaryModuleOwnerGHHandle | Should -BeExactly 'owner-three'
        $row.PrimaryModuleOwnerDisplayName | Should -BeExactly ''
        $row.SecondaryModuleOwnerGHHandle | Should -BeExactly 'owner-one'
        $row.SecondaryModuleOwnerDisplayName | Should -BeExactly 'Profile One'
        $row.ModuleOwnersGHTeam | Should -BeExactly '@Azure/avm-core-modules'
        $bundle.Catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].owners | Should -Be $metadata.owners
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
