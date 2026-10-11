#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'ModuleCatalogFixture.ps1')
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: module catalog helpers' -Tag Component {
    It 'carries optional historical prefixes into the unchanged v1 catalog' {
        $fixture = New-CatalogFixture -AdoptAll
        $bicep = @($fixture.Modules | Where-Object { $_.Ecosystem -eq 'bicep' -and $_.ModuleType -eq 'resource' })[0]
        $metadataPath = Join-Path $bicep.Directory 'metadata.json'
        $metadata = Read-AvmCatalogJson -Path $metadataPath
        $metadata.alternativeTelemetryIdPrefixes = @('46d3xbcp.res.previous-one', '46d3xbcp.res.previous-two')
        Save-CatalogJson -Path $metadataPath -Data $metadata
        $child = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository $bicep.Repository `
            -ModulePath "$($bicep.ModulePath)/child" -Canonical $bicep.Canonical -Child -Adopt
        $childPath = Join-Path $child.Directory 'metadata.json'
        $childMetadata = Read-AvmCatalogJson -Path $childPath
        $childMetadata.alternativeTelemetryIdPrefixes = @('46d3xbcp.res.child-previous')
        Save-CatalogJson -Path $childPath -Data $childMetadata

        $bundle = Get-CatalogFixtureBundle -Fixture $fixture
        $json = $bundle.Files['docs/v1/modules.json']
        $catalog = ConvertFrom-Json -InputObject $json -AsHashtable
        $entries = $catalog.modules['Microsoft.Storage/storageAccounts'].bicep
        $rootRecord = @($entries | Where-Object modulePath -eq $bicep.ModulePath)[0]
        $childRecord = @($entries | Where-Object modulePath -eq $child.ModulePath)[0]
        $rootRecord.alternativeTelemetryIdPrefixes | Should -Be $metadata.alternativeTelemetryIdPrefixes
        $childRecord.alternativeTelemetryIdPrefixes | Should -Be $childMetadata.alternativeTelemetryIdPrefixes
        $terraformRecord = $catalog.modules['Microsoft.Storage/storageAccounts'].terraform[0]
        $terraformRecord.Contains('alternativeTelemetryIdPrefixes') | Should -BeTrue
        $terraformRecord.alternativeTelemetryIdPrefixes | Should -HaveCount 0
        $catalog.schemaVersion | Should -Be 1

        $schema = Join-Path $repoRoot (Get-AvmCatalogOutput -Configuration $bundle.Configuration -Kind catalog).schema
        Test-Json -Json $json -SchemaFile $schema | Should -BeTrue
        $rootRecord.Remove('alternativeTelemetryIdPrefixes')
        Test-Json -Json (ConvertTo-AvmCatalogJson -Value $catalog) -SchemaFile $schema | Should -BeTrue
    }

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

    It 'permits Bicep helper removals but protects Terraform helpers through <Destination> generation and publication' -TestCases @(
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
        $held.HeldBackSourceFiles | Should -HaveCount 3
        $held.HeldBackSourceFiles | Should -Be @('TerraformPatternModules.csv', 'TerraformResourceModules.csv', 'TerraformUtilityModules.csv')
        $held.HeldBack | Should -Contain 'docs/v1/modules.json'
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Inventory $inventory -Force
        $bundle.Report.counts.catalogEntries | Should -Be 12
        $bundle.Report.csvRowRemovals | Should -HaveCount 3
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
            if ($output.ecosystem -eq 'bicep') {
                $removals | Should -HaveCount 0
            }
            else {
                $removals | Should -HaveCount 1
                $removals[0].moduleName | Should -Match '/helper$'
            }
            $sourcePath = Join-Path $sourceRoot $output.sourcePath
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($sourcePath))
            Copy-Item -LiteralPath (Join-Path $fixture.Legacy $output.sourceFile) -Destination $sourcePath
        }
        Write-AvmCatalogBundle -Bundle $bundle -OutputPath $fixture.Output -Configuration $configuration | Out-Null
        $publicationRemovals = Get-AvmCatalogPublicationRowRemovals -BundlePath $fixture.Output `
            -Configuration $configuration -SourceRoot $sourceRoot
        $publicationRemovals | Should -HaveCount 3
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

Describe 'Component: module catalog source CSV row retention' -Tag Component {
    It 'permits removed Bicep submodule rows in <Kind> CSV generation and publication without force' -TestCases @(
        @{ Kind = 'resource'; File = 'BicepResourceModules.csv' }
        @{ Kind = 'pattern'; File = 'BicepPatternModules.csv' }
        @{ Kind = 'utility'; File = 'BicepUtilityModules.csv' }
    ) {
        param($Kind, $File)
        $fixture = New-CatalogFixture -AdoptAll
        $family = @($fixture.Modules | Where-Object { $_.Ecosystem -eq 'bicep' -and $_.ModuleType -eq $Kind })[0]
        $rows = @($fixture.Original[$File])
        foreach ($suffix in @('removed-child', 'removed-child/grandchild')) {
            $row = [ordered]@{}
            foreach ($header in $fixture.Headers[$File]) { $row[$header] = $fixture.Original[$File][$header] }
            $row.ModuleName = "$($family.ModulePath)/$suffix"
            $row.RepoURL = "$($family.Identity.RepoURL)/$suffix"
            $rows += $row
        }
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $File),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$File] -Rows $rows))
        $null = Get-CatalogFixtureBundle -Fixture $fixture
        $sourceRoot = Initialize-CatalogPublicationBase -Fixture $fixture
        $diagnostics = Join-Path $fixture.Root 'diagnostics'

        & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root `
            -OutputPath $fixture.Output -DiagnosticsPath $diagnostics | Out-Null

        $report = Read-AvmCatalogJson -Path (Join-Path $fixture.Output 'v1' 'migration-report.json')
        $report.sourceCsvRows[$File] | Should -HaveCount 3
        $report.missingMetadata | Should -HaveCount 2
        $report.csvRowRemovals | Should -HaveCount 0
        $report.csvRowRemovalsForced | Should -BeFalse
        $report.heldBackOutputs | Should -HaveCount 0
        $generated = @(Import-Csv -LiteralPath (Join-Path $fixture.Output 'docs' $File))
        $generated | Should -HaveCount 1
        $generated[0].ModuleName | Should -BeExactly $family.ModulePath
        { Test-AvmCatalogPublicationBundle -Path $fixture.Output } | Should -Not -Throw
        (Get-AvmCatalogPublicationRowRemovals -BundlePath $fixture.Output `
            -Configuration (Read-AvmCatalogConfiguration) -SourceRoot $sourceRoot) | Should -HaveCount 0
        { & (Join-Path $catalogScripts 'Assert-ModuleCatalogPublication.ps1') -DiagnosticsPath $diagnostics } | Should -Not -Throw
    }

    It 'still rejects duplicate Bicep submodule source identities' {
        $fixture = New-CatalogFixture -AdoptAll
        $file = 'BicepResourceModules.csv'
        $row = $fixture.Original[$file]
        $row.ModuleName += '/removed-child'
        $row.RepoURL += '/removed-child'
        [System.IO.File]::WriteAllText((Join-Path $fixture.Legacy $file),
            (ConvertTo-AvmCatalogCsv -Headers $fixture.Headers[$file] -Rows @($row, $row)))
        { Get-CatalogFixtureBundle -Fixture $fixture } | Should -Throw '*Duplicate legacy identity*'
    }

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
