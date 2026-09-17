#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:adapterRoot = Join-Path $repoRoot 'repository-management' 'module-metadata'
    $script:initialize = Join-Path $script:adapterRoot 'Invoke-ModuleMetadataBackfill.ps1'
    . (Join-Path $script:adapterRoot 'MetadataBackfill.ps1')
    . (Join-Path $script:adapterRoot 'BicepOwnerSnapshot.ps1')

    function New-AutomaticMetadataFixture {
        param([switch] $Child, [switch] $Pattern)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), "locals { unrelated = true }`n")
        $id = if ($Pattern) { 'avm-ptn-example-repo' } else { 'avm-res-storage-account' }
        $repository = "Azure/terraform-azurerm-$id"
        $record = @{
            ModuleName = $id
            RepoURL = "https://github.com/$repository"
            ModuleDisplayName = 'Example module'
            Description = 'Creates the example resources.'
            PrimaryModuleOwnerGHHandle = 'first-owner'
            SecondaryModuleOwnerGHHandle = 'second-owner'
            ProviderNamespace = if ($Pattern) { '' } else { 'Microsoft.Storage' }
            ResourceType = if ($Pattern) { '' } else { 'storageAccounts' }
        }
        $records = @($record)
        if ($Child) {
            $childPath = Join-Path $root 'modules' 'blob-service'
            $null = New-Item -ItemType Directory -Path $childPath -Force
            [System.IO.File]::WriteAllText((Join-Path $childPath 'main.tf'), 'locals { child = true }')
            $records += @{
                ModulePath = 'modules/blob-service'
                RepoURL = "https://github.com/$repository"
                ModuleDisplayName = 'Blob service'
                Description = 'Creates a blob service.'
                CanonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
                TelemetryIdPrefix = '46d3xtrf.res.storage-blobservice'
            }
        }
        [pscustomobject]@{
            Root = $root
            Records = $records
            Parameters = @{ RepositoryRoot = $root; Repository = $repository; Ecosystem = 'terraform'; LegacyRecord = $records }
        }
    }
}

Describe 'Component: automatic metadata file creation' -Tag Component {
    It 'accepts the verified macOS system temporary alias and returns its physical checkout path' -Skip:(-not $IsMacOS) {
        $systemRoot = [System.IO.Path]::GetPathRoot($TestDrive)
        $alias = Join-Path $systemRoot 'tmp'
        $name = 'avm-metadata-alias-' + [guid]::NewGuid().ToString('N')
        $path = Join-Path $alias $name
        $expected = Join-Path $systemRoot 'private' 'tmp' $name
        $previousTemporary = $env:TMPDIR
        try {
            $env:TMPDIR = $alias
            $null = New-Item -ItemType Directory -Path $path
            Resolve-AvmMetadataBackfillRoot -Path $path | Should -BeExactly $expected
            Test-Path -LiteralPath $expected -PathType Container | Should -BeTrue
        }
        finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            [Environment]::SetEnvironmentVariable('TMPDIR', $previousTemporary)
        }
    }

    It 'rejects caller-controlled <LinkKind> links without creating metadata' -TestCases @(
        @{ LinkKind = 'checkout' }
        @{ LinkKind = 'ancestor' }
        @{ LinkKind = 'module' }
    ) {
        param($LinkKind)
        $fixture = New-AutomaticMetadataFixture
        $link = if ($LinkKind -ceq 'module') {
            $parent = Join-Path $fixture.Root 'modules'
            $null = New-Item -ItemType Directory -Path $parent
            Join-Path $parent 'linked'
        } else { Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
        $itemType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $target = if ($LinkKind -ceq 'ancestor') { Split-Path $fixture.Root -Parent } else { $fixture.Root }
        $null = New-Item -ItemType $itemType -Path $link -Target $target
        try {
            $parameters = $fixture.Parameters.Clone()
            if ($LinkKind -ceq 'checkout') { $parameters.RepositoryRoot = $link }
            if ($LinkKind -ceq 'ancestor') { $parameters.RepositoryRoot = Join-Path $link (Split-Path $fixture.Root -Leaf) }
            { & $script:initialize @parameters } | Should -Throw '*Reparse*'
            Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    It 'creates missing metadata directly from existing rows with no approval file or registry' {
        $fixture = New-AutomaticMetadataFixture
        $parameters = $fixture.Parameters
        $result = & $script:initialize @parameters
        $result.Status | Should -Be 'pass'
        $result.Changed | Should -BeTrue
        $metadata = Get-Content (Join-Path $fixture.Root 'metadata.json') -Raw | ConvertFrom-Json
        $metadata.moduleDescription | Should -Be 'Creates the example resources.'
        $metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts'
        $metadata.owners | Should -Be @('first-owner', 'second-owner')
        $metadata.PSObject.Properties.Name | Should -Not -Contain 'tier'
        $metadata.PSObject.Properties.Name | Should -Not -Contain 'schemaVersion'
        Test-Path (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
        Test-Path (Join-Path $script:adapterRoot 'reviewed-seeds.json') | Should -BeFalse
    }

    It 'supports the example pattern repository without a hand-written intermediate file' {
        $fixture = New-AutomaticMetadataFixture -Pattern
        $parameters = $fixture.Parameters
        $null = & $script:initialize @parameters
        $metadata = Get-Content (Join-Path $fixture.Root 'metadata.json') -Raw | ConvertFrom-Json
        $metadata.canonicalType | Should -Be 'example/repo'
        $metadata.telemetryIdPrefix | Should -Be '46d3xtrf.ptn.example-repo'
    }

    It 'reads the example repository description while ignoring its warning block' {
        $fixture = New-AutomaticMetadataFixture -Pattern
        $fixture.Records[0].Remove('Description')
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root '_header.md'), @'
# Azure Verified Module Example Repository

This repository serves as a test sandbox for the Azure Verified Modules team.

> [!WARNING]
> For internal AVM use only.
'@)
        $parameters = $fixture.Parameters
        $null = & $script:initialize @parameters
        $metadata = Get-Content (Join-Path $fixture.Root 'metadata.json') -Raw | ConvertFrom-Json
        $metadata.moduleDescription | Should -Be 'This repository serves as a test sandbox for the Azure Verified Modules team.'
    }

    It 'creates reduced child metadata and preserves root ownership' {
        $fixture = New-AutomaticMetadataFixture -Child
        $parameters = $fixture.Parameters
        $result = & $script:initialize @parameters
        $result.Modules.Count | Should -Be 2
        $child = Get-Content (Join-Path $fixture.Root 'modules' 'blob-service' 'metadata.json') -Raw | ConvertFrom-Json -AsHashtable
        $child.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts/blobServices'
        $child.Contains('owners') | Should -BeFalse
        $child.Contains('tier') | Should -BeFalse
    }

    It 'leaves every existing metadata byte unchanged even when input data changes' {
        $fixture = New-AutomaticMetadataFixture
        $parameters = $fixture.Parameters
        $null = & $script:initialize @parameters
        $path = Join-Path $fixture.Root 'metadata.json'
        $before = [System.IO.File]::ReadAllBytes($path)
        $fixture.Records[0].ModuleDisplayName = 'Changed index'
        $result = & $script:initialize @parameters
        $result.Changed | Should -BeFalse
        [System.IO.File]::ReadAllBytes($path) | Should -Be $before
        Test-Path (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
    }

    It 'rejects Terraform source updates even with existing metadata or WhatIf: <Existing>, <Preview>' -TestCases @(
        @{ Existing = $false; Preview = $false }
        @{ Existing = $false; Preview = $true }
        @{ Existing = $true; Preview = $false }
        @{ Existing = $true; Preview = $true }
    ) {
        param($Existing, $Preview)
        $fixture = New-AutomaticMetadataFixture -Child
        $parameters = $fixture.Parameters
        if ($Existing) { $null = & $script:initialize @parameters }
        $before = @(Get-ChildItem $fixture.Root -File -Recurse | Get-FileHash | ForEach-Object { "$($_.Path):$($_.Hash)" })
        { & $script:initialize @parameters -UpdateSource -WhatIf:$Preview } |
            Should -Throw '*Terraform -UpdateSource is not supported*'
        @(Get-ChildItem $fixture.Root -File -Recurse | Get-FileHash | ForEach-Object { "$($_.Path):$($_.Hash)" }) |
            Should -Be $before
        @(Get-ChildItem $fixture.Root -Filter 'main.metadata.tf' -Recurse) | Should -HaveCount 0
    }

    It 'preserves an existing authored Terraform reader during backfill' {
        $fixture = New-AutomaticMetadataFixture
        $parameters = $fixture.Parameters
        $path = Join-Path $fixture.Root 'main.metadata.tf'
        $source = "locals { authored = true }`n"
        [System.IO.File]::WriteAllText($path, $source)
        ($result = & $script:initialize @parameters).Changed | Should -BeTrue
        $result.Modules[0].PlannedFiles | Should -Be @('metadata.json')
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $source
    }

    It 'reports planned files without writing them under WhatIf' {
        $fixture = New-AutomaticMetadataFixture -Child
        $parameters = $fixture.Parameters
        $result = & $script:initialize @parameters -WhatIf
        $result.Status | Should -Be 'planned'
        $result.Changed | Should -BeFalse
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
        Test-Path (Join-Path $fixture.Root 'modules' 'blob-service' 'metadata.json') | Should -BeFalse
    }

    It 'rejects missing information before writing any module file' {
        $fixture = New-AutomaticMetadataFixture -Child
        $fixture.Records[1].Remove('CanonicalType')
        $parameters = $fixture.Parameters
        { & $script:initialize @parameters } | Should -Throw '*canonicalType*'
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'honors a disabled child before making any root changes' {
        $fixture = New-AutomaticMetadataFixture -Child
        $disabled = Join-Path $fixture.Root 'modules' 'blob-service' '.avm'
        $null = New-Item -ItemType Directory -Path $disabled
        [System.IO.File]::WriteAllText((Join-Path $disabled '.disable'), '')
        $parameters = $fixture.Parameters
        { & $script:initialize @parameters } | Should -Throw '*disabled*'
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'reads existing CSV files directly and does not run module source' {
        $fixture = New-AutomaticMetadataFixture
        $csv = Join-Path $TestDrive 'existing-index.csv'
        [pscustomobject]$fixture.Records[0] | Export-Csv -LiteralPath $csv -NoTypeInformation
        $result = & $script:initialize -RepositoryRoot $fixture.Root -Repository $fixture.Parameters.Repository `
            -Ecosystem terraform -LegacyCsvPath $csv
        $result.Status | Should -Be 'pass'
        Get-Content (Join-Path $fixture.Root 'main.tf') -Raw | Should -BeExactly "locals { unrelated = true }`n"
    }

    It 'rejects unsafe paths and preserves the checkout boundary' -TestCases @(
        @{ Relative = '../outside' }
        @{ Relative = '/outside' }
        @{ Relative = 'modules/../outside' }
        @{ Relative = 'modules\outside' }
        @{ Relative = 'metadata.json:stream' }
    ) {
        param($Relative)
        $fixture = New-AutomaticMetadataFixture
        { Resolve-AvmMetadataBackfillPath -Root $fixture.Root -RelativePath $Relative } | Should -Throw
    }
}

Describe 'Component: metadata values from existing source' -Tag Component {
    It 'classifies Oracle ARM types in the optional Bicep source reader: <Canonical>' -TestCases @(
        @{ Canonical = 'Oracle.Database/cloudExadataInfrastructures'; Status = 'pass' }
        @{ Canonical = 'Oracle.Database/cloudVmClusters'; Status = 'pass' }
        @{ Canonical = 'Oracle.Database/autonomousDatabases'; Status = 'pass' }
        @{ Canonical = 'Oracle.Other/cloudVmClusters'; Status = 'fail' }
        @{ Canonical = 'Oracle.Database/cloudVmClusters/Microsoft.Insights/diagnosticSettings'; Status = 'fail' }
    ) {
        param($Canonical, $Status)
        $fixture = New-AutomaticMetadataFixture
        $sourcePath = Join-Path $fixture.Root 'main.bicep'
        [System.IO.File]::WriteAllText($sourcePath, @"
metadata name = 'Oracle child'
metadata description = 'Creates an Oracle resource.'
resource database '$Canonical@2025-09-01' = {}
"@)
        $before = [System.IO.File]::ReadAllBytes($sourcePath)
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId 'avm/res/oracle/database/child' `
            -Ecosystem bicep -ModuleType resource -ChildModule -SkipModuleVersionCheck
        $result.Status | Should -Be $Status
        if ($Status -eq 'pass') {
            $result.Metadata.canonicalType | Should -BeExactly $Canonical
            $result.Metadata.Contains('owners') | Should -BeFalse
            $result.Metadata.Contains('telemetryIdPrefix') | Should -BeFalse
        }
        else {
            $result.Candidate.Contains('canonicalType') | Should -BeFalse
        }
        [System.IO.File]::ReadAllBytes($sourcePath) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'does not infer a canonical type from mixed Oracle and Microsoft Bicep resources' {
        $fixture = New-AutomaticMetadataFixture
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'main.bicep'), @'
metadata name = 'Multiple resources'
metadata description = 'Canonical identity must be supplied.'
resource database 'Oracle.Database/cloudVmClusters@2025-09-01' = {}
resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {}
'@)
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId 'avm/res/oracle/database/child' `
            -Ecosystem bicep -ModuleType resource -ChildModule -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Candidate.Contains('canonicalType') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'derives Bicep values in migration scripts while the permanent reader still requires a file' {
        $fixture = New-AutomaticMetadataFixture
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'main.bicep'), @'
metadata name = 'Bicep source name'
metadata description = 'Bicep source description.'
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = {
  name: '46d3xbcp.res.storage-account.suffix'
}
'@)
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId 'avm/res/storage/storage-account' `
            -Ecosystem bicep -ModuleType resource -LegacyRecord $fixture.Records -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Metadata.moduleDisplayName | Should -BeExactly 'Bicep source name'
        $result.Metadata.moduleDescription | Should -BeExactly 'Bicep source description.'
        $result.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xbcp.res.storage-account'
        (Get-AvmModuleMetadata -Path $fixture.Root -Ecosystem bicep -ModuleType resource -SkipModuleVersionCheck).Status |
            Should -Be 'fail'
        Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'keeps a single alternative name as an array and allows real one-letter resource types' {
        $fixture = New-AutomaticMetadataFixture
        $fixture.Records[0].AlternativeNames = 'DNS'
        $fixture.Records[0].ResourceType = 'dnsZones/A'
        $fixture.Records[0].ProviderNamespace = 'Microsoft.Network'
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId 'avm-res-network-dnszone' `
            -Ecosystem terraform -ModuleType resource -LegacyRecord $fixture.Records -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        ($result.Metadata.alternativeNames -is [array]) | Should -BeTrue
        $result.Metadata.alternativeNames.Count | Should -Be 1
        $result.Metadata.canonicalType | Should -Be 'Microsoft.Network/dnsZones/A'
    }

    It 'keeps every supplied owner handle without personal-name fields' {
        $fixture = New-AutomaticMetadataFixture
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId 'avm-res-storage-account' `
            -Ecosystem terraform -ModuleType resource -LegacyRecord $fixture.Records `
            -OwnerGitHubHandle @('FIRST-OWNER', 'third-owner', 'fourth-owner') -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Metadata.owners | Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner')
        foreach ($owner in $result.Metadata.owners) { $owner | Should -BeOfType ([string]) }
    }

    It 'does not invent an owner when both the index and source are unowned' {
        $fixture = New-AutomaticMetadataFixture
        $fixture.Records[0].PrimaryModuleOwnerGHHandle = ''
        $fixture.Records[0].SecondaryModuleOwnerGHHandle = ''
        $parameters = $fixture.Parameters
        $null = & $script:initialize @parameters
        $metadata = Get-Content (Join-Path $fixture.Root 'metadata.json') -Raw | ConvertFrom-Json
        $metadata.owners.Count | Should -Be 0
    }
}

Describe 'Component: single-segment metadata backfill' -Tag Component {
    BeforeAll {
        . (Join-Path $script:adapterRoot '..' 'module-catalog' 'scripts' 'ModuleCatalog.ps1')
    }

    It 'round-trips <ModuleId> and a reduced child through backfill, authoring checks, and catalog output' -TestCases @(
        @{ ModuleId = 'avm-utl-naming'; ModuleType = 'utility'; Canonical = 'naming'; DisplayName = 'Module Naming' }
        @{ ModuleId = 'avm-ptn-alz'; ModuleType = 'pattern'; Canonical = 'alz'; DisplayName = 'Illustrative pattern' }
        @{ ModuleId = 'avm-utl-helpers2'; ModuleType = 'utility'; Canonical = 'helpers2'; DisplayName = 'Example utility' }
    ) {
        param($ModuleId, $ModuleType, $Canonical, $DisplayName)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $bicep = Join-Path $root 'bicep'
        $terraform = Join-Path $root 'terraform'
        $legacy = Join-Path $root 'legacy'
        $repository = "Azure/terraform-azure-$ModuleId"
        $moduleRoot = Join-Path $terraform "terraform-azure-$ModuleId"
        $childPath = Join-Path $moduleRoot 'modules' 'helper'
        $null = New-Item -ItemType Directory -Path $bicep, $legacy, $childPath -Force
        $source = "locals { unrelated = true }`n"
        foreach ($path in @($moduleRoot, $childPath)) {
            [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'), $source)
        }
        [System.IO.File]::WriteAllText((Join-Path $moduleRoot '_header.md'), "# $DisplayName`n`nProvides an example module.`n")
        $row = [ordered]@{
            ModuleName = $ModuleId
            ModuleDisplayName = $DisplayName
            RepoURL = "https://github.com/$repository"
            ModuleStatus = 'Proposed'
            Description = ''
            PrimaryModuleOwnerGHHandle = 'jaredfholgate'
            SecondaryModuleOwnerGHHandle = ''
        }
        $configuration = Read-AvmCatalogConfiguration
        foreach ($output in $configuration.outputs | Where-Object kind -eq 'csv') {
            $rows = @(if ($output.ecosystem -eq 'terraform' -and $output.moduleType -eq $ModuleType) { $row })
            $csv = ConvertTo-AvmCatalogCsv -Headers @($row.Keys) -Rows $rows
            [System.IO.File]::WriteAllText((Join-Path $legacy $output.sourceFile), $csv)
        }
        [System.IO.File]::WriteAllText((Join-Path $legacy 'BicepMARModules.json'), "[]`n")
        $csvOutput = @($configuration.outputs | Where-Object {
                $_.kind -eq 'csv' -and $_.ecosystem -eq 'terraform' -and $_.moduleType -eq $ModuleType
            })[0]
        $childRow = @{
            ModulePath = 'modules/helper'
            RepoURL = "https://github.com/$repository"
            ModuleDisplayName = 'Helper'
            Description = 'Provides a helper.'
            CanonicalType = 'helper'
        }
        if ($ModuleType -eq 'pattern') {
            $childRow.TelemetryIdPrefix = "46d3xtrf.ptn.$Canonical-helper"
        }
        $result = & $script:initialize -RepositoryRoot $moduleRoot -Repository $repository -Ecosystem terraform `
            -LegacyCsvPath (Join-Path $legacy $csvOutput.sourceFile) -LegacyRecord @($childRow)
        $result.Status | Should -Be 'pass'
        $result.Modules | Should -HaveCount 2
        foreach ($plan in $result.Modules) { $plan.PlannedFiles | Should -Be @('metadata.json') }
        $metadata = Read-AvmCatalogJson -Path (Join-Path $moduleRoot 'metadata.json')
        $metadata.canonicalType | Should -BeExactly $Canonical
        $metadata.moduleDisplayName | Should -BeExactly $DisplayName
        $metadata.moduleDescription | Should -BeExactly 'Provides an example module.'
        $metadata.owners | Should -Be @('jaredfholgate')
        $metadata.Contains('telemetryIdPrefix') | Should -Be ($ModuleType -eq 'pattern')
        if ($ModuleType -eq 'pattern') {
            $metadata.telemetryIdPrefix | Should -BeExactly "46d3xtrf.ptn.$Canonical"
        }
        $childMetadata = Read-AvmCatalogJson -Path (Join-Path $childPath 'metadata.json')
        $childMetadata.canonicalType | Should -BeExactly 'helper'
        $childMetadata.Contains('owners') | Should -BeFalse
        $authoring = Get-Module Avm.Authoring
        $validation = & $authoring {
            param($Path)
            Test-AvmMetadataModules -Context ([pscustomobject]@{ Root = $Path; Ecosystem = 'terraform'; Kind = 'terraform-module-repo' })
        } $moduleRoot
        $validation.Status | Should -Be 'pass'
        $validation.Issues | Should -HaveCount 0

        $inventory = Get-AvmCatalogInventory -BicepRoot $bicep -TerraformRoot $terraform -LegacyPath $legacy
        $registry = @{}
        foreach ($item in $inventory.Items) {
            $registry[$item.Identity.Key] = @{
                status = 'not-published'; currentVersion = $null; firstPublishedIn = $null
                downloads = $null; marRegistered = $null
            }
        }
        $github = @{
            users = @{ jaredfholgate = @{ login = 'jaredfholgate'; name = $null; type = 'User' } }
            teams = @{}
        }
        $bundle = New-AvmCatalogBundle -Inventory $inventory -Registry $registry -GitHub $github `
            -RepositoryRevisions @(@{ repository = $repository; commit = 'a' * 40; status = 'collected'; archived = $false })
        $outputPath = Join-Path $root 'generated'
        Write-AvmCatalogBundle -Bundle $bundle -OutputPath $outputPath
        $catalogPath = (Get-AvmCatalogOutput -Configuration $configuration -Kind catalog).bundlePath
        $catalog = Read-AvmCatalogJson -Path (Join-Path $outputPath $catalogPath)
        $catalog.modules.Count | Should -Be 2
        foreach ($canonicalType in @($Canonical, 'helper')) {
            $record = $catalog.modules[$canonicalType].terraform[0]
            $record.canonicalType | Should -BeExactly $canonicalType
            $record.owners | Should -Be @('jaredfholgate')
            $record.provider | Should -BeExactly 'azure'
            ($null -eq $record.providerNamespace) | Should -BeTrue
            ($null -eq $record.resourceType) | Should -BeTrue
            if ($ModuleType -eq 'utility') { ($null -eq $record.telemetryIdPrefix) | Should -BeTrue }
        }
        ($null -eq $catalog.modules[$Canonical].terraform[0].parentModule) | Should -BeTrue
        $catalog.modules['helper'].terraform[0].parentModule | Should -BeExactly '.'
        $catalog.modules['helper'].terraform[0].familyModule | Should -BeExactly '.'
        $catalog.modules['helper'].terraform[0].modulePath | Should -BeExactly 'modules/helper'
        $generatedRows = @($bundle.Files[$csvOutput.bundlePath] | ConvertFrom-Csv)
        @($generatedRows.CanonicalType | Sort-Object) | Should -Be @(@($Canonical, 'helper') | Sort-Object)
        $bundle.Report.csvRowRemovals | Should -HaveCount 0
        foreach ($path in @($moduleRoot, $childPath)) {
            [System.IO.File]::ReadAllText((Join-Path $path 'main.tf')) | Should -BeExactly $source
            Test-Path -LiteralPath (Join-Path $path 'main.metadata.tf') | Should -BeFalse
        }
    }

    It 'preserves explicit canonical precedence and existing mappings: <Case>' -TestCases @(
        @{ Case = 'single CSV value'; ModuleId = 'avm-utl-naming'; Kind = 'utility'; Csv = 'shared'; Override = @{}; Expected = 'shared' }
        @{ Case = 'override before CSV'; ModuleId = 'avm-utl-naming'; Kind = 'utility'; Csv = 'types/common'; Override = @{ canonicalType = 'supplied' }; Expected = 'supplied' }
        @{ Case = 'explicit multi-segment'; ModuleId = 'avm-utl-naming'; Kind = 'utility'; Csv = 'types/common'; Override = @{}; Expected = 'types/common' }
        @{ Case = 'ambiguous name with explicit value'; ModuleId = 'avm-ptn-long-hyphenated-name'; Kind = 'pattern'; Csv = 'alz'; Override = @{}; Expected = 'alz' }
        @{ Case = 'existing two-part utility'; ModuleId = 'avm-utl-types-common'; Kind = 'utility'; Csv = ''; Override = @{}; Expected = 'types/common' }
    ) {
        param($ModuleId, $Kind, $Csv, $Override, $Expected)
        $fixture = New-AutomaticMetadataFixture -Pattern
        $fixture.Records[0].CanonicalType = $Csv
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId $ModuleId `
            -Ecosystem terraform -ModuleType $Kind -LegacyRecord $fixture.Records -Override $Override -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Metadata.canonicalType | Should -BeExactly $Expected
    }

    It 'does not guess a canonical type from unsupported names: <ModuleId>' -TestCases @(
        @{ ModuleId = 'avm-utl-'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl--naming'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-naming-'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-naming--helper'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-Naming'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-naming_helper'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-../naming'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-naming/child'; Kind = 'utility' }
        @{ ModuleId = 'avm-utl-types-common-extra'; Kind = 'utility' }
        @{ ModuleId = 'avm-ptn-team-long-name'; Kind = 'pattern' }
        @{ ModuleId = 'avm-res-naming'; Kind = 'resource' }
    ) {
        param($ModuleId, $Kind)
        $fixture = New-AutomaticMetadataFixture -Pattern
        $result = Get-AvmMetadataBackfillCandidate -Path $fixture.Root -ModuleId $ModuleId `
            -Ecosystem terraform -ModuleType $Kind -LegacyRecord $fixture.Records -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Candidate.Contains('canonicalType') | Should -BeFalse
        @($result.Issues | Where-Object { $_.Code -eq 'AVM_METADATA_REQUIRED' -and $_.Message -like '*canonicalType*' }) |
            Should -HaveCount 1
        Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'preserves grouped Bicep module path requirements for <Kind>' -TestCases @(
        @{ Kind = 'res' }, @{ Kind = 'ptn' }, @{ Kind = 'utl' }
    ) {
        param($Kind)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $root 'avm' $Kind 'example'
        $null = New-Item -ItemType Directory -Path $path -Force
        [System.IO.File]::WriteAllText((Join-Path $path 'main.bicep'), "metadata name = 'Example'`nmetadata description = 'Example module.'`n")
        { Get-AvmMetadataBackfillModule -Root $root -Repository Azure/bicep-registry-modules -Ecosystem bicep } |
            Should -Throw '*expected avm/kind/group/name*'
    }
}
