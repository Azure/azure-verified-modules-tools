#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'ModuleCatalogFixture.ps1')
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
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
            @{ Case = 'published helper'; Ecosystem = 'terraform' }
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
                        Add-CatalogModule -Fixture $fixture -Ecosystem terraform -Repository $module.Repository `
                            -ModulePath 'modules/helper' -Canonical 'helper' -Child -Adopt
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

    It 'derives a multi-scope Bicep parent status for <Case> without inventing a parent release' -TestCases @(
        @{ Case = 'only management-group scope published'; Published = @('mg-scope'); Owned = $true; Deprecated = $false; Expected = 'Available' }
        @{ Case = 'only subscription scope published'; Published = @('sub-scope'); Owned = $true; Deprecated = $false; Expected = 'Available' }
        @{ Case = 'only resource-group scope published'; Published = @('rg-scope'); Owned = $true; Deprecated = $false; Expected = 'Available' }
        @{ Case = 'all scopes published'; Published = @('mg-scope', 'rg-scope', 'sub-scope'); Owned = $true; Deprecated = $false; Expected = 'Available' }
        @{ Case = 'no scopes published'; Published = @(); Owned = $true; Deprecated = $false; Expected = 'Proposed' }
        @{ Case = 'published scope without owners'; Published = @('rg-scope'); Owned = $false; Deprecated = $false; Expected = 'Orphaned' }
        @{ Case = 'deprecated published scope'; Published = @('sub-scope'); Owned = $true; Deprecated = $true; Expected = 'Deprecated' }
        @{ Case = 'deprecated unpublished scopes'; Published = @(); Owned = $true; Deprecated = $true; Expected = 'Excluded' }
    ) {
        param($Case, $Published, $Owned, $Deprecated, $Expected)
        $fixture = New-CatalogFixture -AdoptAll
        $parent = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' `
            -ModulePath 'avm/res/authorization/role-assignment' -Canonical 'Microsoft.Authorization/roleAssignments' -Adopt
        $scopes = @(foreach ($name in @('mg-scope', 'rg-scope', 'sub-scope')) {
                Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository $parent.Repository `
                    -ModulePath "$($parent.ModulePath)/$name" -Canonical $parent.Canonical -Child -Adopt
            })
        if (-not $Owned) {
            $path = Join-Path $parent.Directory 'metadata.json'
            $metadata = Read-AvmCatalogJson -Path $path
            $metadata.owners = @()
            Save-CatalogJson -Path $path -Data $metadata
        }
        if ($Deprecated) {
            [System.IO.File]::WriteAllText((Join-Path $parent.Directory 'DEPRECATED.md'), 'Retired module.')
        }
        $unpublished = @($parent.Identity.Key) + @($scopes | Where-Object {
                $Published -cnotcontains $_.ModulePath.Split('/')[-1]
            } | ForEach-Object { $_.Identity.Key })
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $unpublished
        $catalog = ConvertFrom-Json -InputObject $bundle.Files['docs/v1/modules.json'] -AsHashtable
        $rows = @($bundle.Files['docs/BicepResourceModules.csv'] | ConvertFrom-Csv)
        $records = @(if ($catalog.modules.Contains($parent.Canonical)) { $catalog.modules[$parent.Canonical].bicep })
        $rootRecord = @($records | Where-Object modulePath -CEQ $parent.ModulePath)
        $rootRow = @($rows | Where-Object ModuleName -CEQ $parent.ModulePath)
        if ($Expected -eq 'Excluded') {
            $rootRecord | Should -HaveCount 0
            $rootRow | Should -HaveCount 0
            $bundle.Report.excludedModules | Should -HaveCount 4
        }
        else {
            $rootRecord | Should -HaveCount 1
            $rootRecord[0].moduleStatus | Should -BeExactly $Expected
            $rootRow | Should -HaveCount 1
            $rootRow[0].ModuleStatus | Should -BeExactly $Expected
            $rootRecord[0].registry.status | Should -BeExactly 'not-published'
            $rootRecord[0].registry.currentVersion | Should -BeNullOrEmpty
            $rootRecord[0].registry.firstPublishedIn | Should -BeNullOrEmpty
            $rootRecord[0].registry.marRegistered | Should -BeTrue
            $rootRecord[0].publicRegistryReference | Should -BeExactly $parent.Identity.Reference
            @($bundle.Report.excludedModules | ForEach-Object { $_.modulePath }) | Should -Not -Contain $parent.ModulePath
        }
        foreach ($scope in $scopes) {
            $publishedScope = $Published -ccontains $scope.ModulePath.Split('/')[-1]
            $record = @($records | Where-Object modulePath -CEQ $scope.ModulePath)
            if ($Deprecated -and -not $publishedScope) {
                $record | Should -HaveCount 0
                continue
            }
            $record | Should -HaveCount 1
            $scopeStatus = if ($Deprecated) { 'Deprecated' } elseif (-not $publishedScope) { 'Proposed' } elseif ($Owned) { 'Available' } else { 'Orphaned' }
            $record[0].moduleStatus | Should -BeExactly $scopeStatus
            $record[0].registry.status | Should -BeExactly $(if ($publishedScope) { 'available' } else { 'not-published' })
        }
        $bundle.HeldBack | Should -HaveCount 0
        $catalog.modules['Microsoft.Storage/storageAccounts'].bicep[0].moduleStatus | Should -BeExactly 'Available'
    }

    It 'rejects incomplete multi-scope publication evidence: <Case>' -TestCases @(
        @{ Case = 'missing scope registry entry' }
        @{ Case = 'invalid scope registry entry' }
        @{ Case = 'missing scope source' }
        @{ Case = 'missing parent source' }
    ) {
        param($Case)
        $fixture = New-CatalogFixture -AdoptAll
        $parent = $fixture.Modules[0]
        $scope = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository $parent.Repository `
            -ModulePath "$($parent.ModulePath)/rg-scope" -Canonical $parent.Canonical -Child -Adopt
        $null = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $parent.Identity.Key
        $registryPath = Join-Path $fixture.Root 'registry.json'
        $registry = Read-AvmCatalogJson -Path $registryPath
        switch ($Case) {
            'missing scope registry entry' { $registry.Remove($scope.Identity.Key) }
            'invalid scope registry entry' { $registry[$scope.Identity.Key].currentVersion = $null }
            'missing scope source' { [System.IO.File]::Delete((Join-Path $scope.Directory 'main.bicep')) }
            'missing parent source' { [System.IO.File]::Delete((Join-Path $parent.Directory 'main.bicep')) }
        }
        Save-CatalogJson -Path $registryPath -Data $registry
        { & (Join-Path $catalogScripts 'Invoke-ModuleCatalog.ps1') -InputPath $fixture.Root -OutputPath $fixture.Output } | Should -Throw
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
    }

    It 'does not promote a multi-scope Bicep parent from a <Case> release' -TestCases @(
        @{ Case = 'helper'; Path = 'rg-scope'; Canonical = 'helper' }
        @{ Case = 'nested scope'; Path = 'child/rg-scope'; Canonical = 'Microsoft.Storage/storageAccounts' }
        @{ Case = 'ordinary child'; Path = 'child'; Canonical = 'Microsoft.Storage/storageAccounts' }
    ) {
        param($Case, $Path, $Canonical)
        $fixture = New-CatalogFixture -AdoptAll
        $parent = $fixture.Modules[0]
        $null = Add-CatalogModule -Fixture $fixture -Ecosystem bicep -Repository $parent.Repository `
            -ModulePath "$($parent.ModulePath)/$Path" -Canonical $Canonical -Child -Adopt
        $bundle = Get-CatalogFixtureBundle -Fixture $fixture -Unpublished $parent.Identity.Key
        $record = @($bundle.Catalog.modules[$parent.Canonical].bicep | Where-Object modulePath -CEQ $parent.ModulePath)[0]
        $record.moduleStatus | Should -BeExactly 'Proposed'
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
