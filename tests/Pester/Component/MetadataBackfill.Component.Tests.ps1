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
