#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'ModuleCatalogFixture.ps1')
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
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

    Context 'staging directory move' {
        BeforeEach {
            $script:moveRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:moveSource = Join-Path $script:moveRoot 'staging'
            $script:moveTarget = Join-Path $script:moveRoot 'output'
            $null = New-Item -ItemType Directory -Path $script:moveSource -Force
            $script:lockedFile = Join-Path $script:moveSource 'catalog.json'
            [System.IO.File]::WriteAllText($script:lockedFile, '{}')
            $script:lock = $null
        }

        AfterEach {
            if ($null -ne $script:lock) { $script:lock.Dispose() }
        }

        It 'retries a move refused by a transient file lock' -Skip:(-not $IsWindows) {
            $script:lock = [System.IO.File]::Open($script:lockedFile, 'Open', 'Read', 'None')
            Mock Start-Sleep { $script:lock.Dispose(); $script:lock = $null }

            Move-AvmCatalogStagingDirectory -Source $script:moveSource -Destination $script:moveTarget

            [System.IO.File]::Exists((Join-Path $script:moveTarget 'catalog.json')) | Should -BeTrue
            Should -Invoke Start-Sleep -Exactly 1
        }

        It 'fails after the bounded attempts while the lock persists' -Skip:(-not $IsWindows) {
            $script:lock = [System.IO.File]::Open($script:lockedFile, 'Open', 'Read', 'None')
            Mock Start-Sleep { }

            { Move-AvmCatalogStagingDirectory -Source $script:moveSource -Destination $script:moveTarget -MaxAttempts 3 } |
                Should -Throw
            Should -Invoke Start-Sleep -Exactly 2
            [System.IO.Directory]::Exists($script:moveSource) | Should -BeTrue
        }

        It 'does not retry when the destination already exists' {
            $null = New-Item -ItemType Directory -Path $script:moveTarget
            Mock Start-Sleep { }

            { Move-AvmCatalogStagingDirectory -Source $script:moveSource -Destination $script:moveTarget } |
                Should -Throw
            Should -Invoke Start-Sleep -Exactly 0
        }
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
