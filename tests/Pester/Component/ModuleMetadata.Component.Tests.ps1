#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $schemaPath = Join-Path $moduleRoot 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json'
    $script:metadataSchemaId = (Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json).'$id'

    function New-MetadataFixture {
        param(
            [string] $Ecosystem = 'terraform',
            [string] $ModuleType = 'resource',
            [switch] $ChildModule
        )

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($ChildModule -and $Ecosystem -eq 'terraform') {
            $root = Join-Path $root 'modules' 'child'
        }
        $null = New-Item -ItemType Directory -Path $root -Force
        $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
        $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
        $canonical = if ($ModuleType -eq 'resource') { 'Microsoft.Storage/storageAccounts' } else { 'types/example' }
        $data = [ordered]@{
            '$schema'         = $script:metadataSchemaId
            schemaVersion     = 1
            moduleDisplayName = 'Storage Accounts'
            moduleDescription = 'Deploys a Storage Account.'
            canonicalType     = $canonical
            telemetryIdPrefix = "$marker.$kind.storage-storageaccount"
        }
        if (-not $ChildModule) {
            $data.tier = 'maintained'
            $data.owners = @{ individuals = @(@{ githubHandle = 'azure-owner' }); team = '' }
            $data.alternativeNames = @('Storage')
            $data.comments = ''
        }

        $source = if ($Ecosystem -eq 'bicep') {
            @'
metadata name = 'Storage Accounts'
metadata description = 'Deploys a Storage Account.'

param enableTelemetry bool = true
param location string = resourceGroup().location

resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = if (enableTelemetry) {
  name: 'PREFIX.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name, location), 0, 4)}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
    }
  }
}
'@.Replace('PREFIX', $data.telemetryIdPrefix)
        }
        else {
            "locals {`n  unrelated = true`n}`n"
        }
        $sourcePath = Join-Path $root ("main." + $(if ($Ecosystem -eq 'bicep') { 'bicep' } else { 'tf' }))
        [System.IO.File]::WriteAllText($sourcePath, $source.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        [pscustomobject]@{
            Root         = $root
            Data         = $data
            SourcePath   = $sourcePath
            MetadataPath = Join-Path $root 'metadata.json'
            Parameters   = @{
                Path                   = $root
                Ecosystem              = $Ecosystem
                ModuleType             = $ModuleType
                ChildModule            = $ChildModule.IsPresent
                SkipModuleVersionCheck = $true
            }
        }
    }

    function Save-MetadataFixture {
        param($Fixture)
        $json = ($Fixture.Data | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n"
        [System.IO.File]::WriteAllText($Fixture.MetadataPath, $json, [System.Text.UTF8Encoding]::new($false))
    }
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: shared module metadata schema' -Tag Component {
    It 'accepts both ecosystems and root/child shapes: <Ecosystem>, child=<Child>' -TestCases @(
        @{ Ecosystem = 'bicep'; Child = $false }
        @{ Ecosystem = 'bicep'; Child = $true }
        @{ Ecosystem = 'terraform'; Child = $false }
        @{ Ecosystem = 'terraform'; Child = $true }
    ) {
        param($Ecosystem, $Child)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem -ChildModule:$Child
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -BeExactly 'pass'
        $result.Metadata.canonicalType | Should -BeExactly 'Microsoft.Storage/storageAccounts'
        $result.Issues.Count | Should -Be 0
    }

    It 'accepts team-only ownership without storing personal names' {
        $fixture = New-MetadataFixture
        $fixture.Data.owners = @{ individuals = @(); team = '@Azure/avm-core-modules' }
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
    }

    It 'preserves all four individual owners rather than imposing legacy CSV slots' {
        $fixture = New-MetadataFixture
        $fixture.Data.owners = @{
            individuals = @(
                @{ githubHandle = 'first-owner' }
                @{ githubHandle = 'second-owner' }
                @{ githubHandle = 'third-owner' }
                @{ githubHandle = 'fourth-owner' }
            )
        }
        $parameters = $fixture.Parameters
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'pass'
        @($result.Metadata.owners.individuals.githubHandle) |
            Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner')
    }

    It 'rejects invalid authored fields: <Case>' -TestCases @(
        @{ Case = 'future tier'; Property = 'tier'; Value = 'open-source' }
        @{ Case = 'tier casing'; Property = 'tier'; Value = 'Core' }
        @{ Case = 'future schema'; Property = 'schemaVersion'; Value = 2 }
        @{ Case = 'missing reference'; Property = '$schema'; Remove = $true }
        @{ Case = 'foreign reference'; Property = '$schema'; Value = 'https://example.invalid/schema.json' }
        @{ Case = 'derived module type'; Property = 'moduleType'; Value = 'resource' }
        @{ Case = 'derived parent'; Property = 'parentModule'; Value = 'parent' }
        @{ Case = 'empty description'; Property = 'moduleDescription'; Value = '' }
        @{ Case = 'whitespace name'; Property = 'moduleDisplayName'; Value = ' ' }
        @{ Case = 'wrong canonical kind'; Property = 'canonicalType'; Value = 'types/example' }
        @{ Case = 'invalid canonical'; Property = 'canonicalType'; Value = 'Microsoft.Storage' }
        @{ Case = 'wrong ecosystem'; Property = 'telemetryIdPrefix'; Value = '46d3xbcp.res.storage-storageaccount' }
        @{ Case = 'wrong telemetry kind'; Property = 'telemetryIdPrefix'; Value = '46d3xtrf.ptn.storage-storageaccount' }
        @{ Case = 'missing telemetry'; Property = 'telemetryIdPrefix'; Remove = $true }
        @{ Case = 'no owners'; Property = 'owners'; Value = @{ individuals = @(); team = '' } }
        @{ Case = 'owner PII'; Property = 'owners'; Value = @{ individuals = @(@{ githubHandle = 'owner'; displayName = 'Personal Name' }) } }
        @{ Case = 'duplicate handle casing'; Property = 'owners'; Value = @{ individuals = @(@{ githubHandle = 'owner' }, @{ githubHandle = 'Owner' }) } }
        @{ Case = 'invalid team'; Property = 'owners'; Value = @{ individuals = @(); team = 'Azure/team' } }
        @{ Case = 'duplicate alternative'; Property = 'alternativeNames'; Value = @('Storage', 'Storage') }
    ) {
        param($Property, $Value, $Remove)
        $fixture = New-MetadataFixture
        if ($Remove) {
            $fixture.Data.Remove($Property)
        }
        else {
            $fixture.Data[$Property] = $Value
        }
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'fail'
        $result.Issues.Count | Should -BeGreaterThan 0
    }

    It 'enforces each transport limit at the exact boundary: <Ecosystem> length <Length>' -TestCases @(
        @{ Ecosystem = 'bicep'; Length = 50; Status = 'pass' }
        @{ Ecosystem = 'bicep'; Length = 51; Status = 'fail' }
        @{ Ecosystem = 'terraform'; Length = 59; Status = 'pass' }
        @{ Ecosystem = 'terraform'; Length = 60; Status = 'fail' }
    ) {
        param($Ecosystem, $Length, $Status)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem
        $fixture.Data.telemetryIdPrefix = $fixture.Data.telemetryIdPrefix.PadRight($Length, 'a')
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Status | Should -Be $Status
    }

    It 'requires telemetry for patterns but permits a utility without telemetry' {
        foreach ($kind in @('pattern', 'utility')) {
            $fixture = New-MetadataFixture -ModuleType $kind
            $fixture.Data.Remove('telemetryIdPrefix')
            Save-MetadataFixture -Fixture $fixture
            $parameters = $fixture.Parameters
            $expected = if ($kind -eq 'utility') { 'pass' } else { 'fail' }
            (Test-AvmModuleMetadata @parameters).Status | Should -Be $expected
        }
    }

    It 'does not confuse the reduced child shape with a root' {
        $fixture = New-MetadataFixture -ChildModule
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $parameters.ChildModule = $false
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
    }

    It 'rejects owners or tier repeated on a child' {
        $fixture = New-MetadataFixture -ChildModule
        $fixture.Data.tier = 'core'
        $fixture.Data.owners = @{ individuals = @(@{ githubHandle = 'owner' }) }
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
    }

    It 'reports missing or malformed metadata rather than passing or falling back' {
        $fixture = New-MetadataFixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Issues[0].Code | Should -Be 'AVM_METADATA_MISSING'
        [System.IO.File]::WriteAllText($fixture.MetadataPath, '{"schemaVersion":1,}')
        (Test-AvmModuleMetadata @parameters).Issues[0].Code | Should -Be 'AVM_METADATA_JSON'
    }

    It 'rejects a BOM or invalid UTF-8 rather than validating a silently decoded replacement' {
        $fixture = New-MetadataFixture
        $parameters = $fixture.Parameters
        $json = $fixture.Data | ConvertTo-Json -Depth 20
        $bytes = [byte[]]@(239, 187, 191) + [System.Text.Encoding]::UTF8.GetBytes($json)
        [System.IO.File]::WriteAllBytes($fixture.MetadataPath, $bytes)
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
        [System.IO.File]::WriteAllBytes($fixture.MetadataPath, [byte[]]@(123, 34, 255, 34, 58, 49, 125))
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
    }

    It 'compares Bicep source literals without compiling or writing files' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $before = (Get-FileHash -LiteralPath $fixture.SourcePath).Hash
        (Test-AvmModuleMetadata @parameters -CheckSource).Status | Should -Be 'pass'
        $fixture.Data.moduleDescription = 'A different description.'
        Save-MetadataFixture -Fixture $fixture
        $result = Test-AvmModuleMetadata @parameters -CheckSource
        $result.Status | Should -Be 'fail'
        $result.Issues[0].File | Should -Be 'main.bicep'
        (Get-FileHash -LiteralPath $fixture.SourcePath).Hash | Should -Be $before
    }
}

Describe 'Component: non-overwriting metadata initialization' -Tag Component {
    It 'honors the disable sentinel for both direct metadata commands' {
        $fixture = New-MetadataFixture
        $directory = Join-Path $fixture.Root '.avm'
        $null = New-Item -ItemType Directory -Path $directory
        [System.IO.File]::WriteAllText((Join-Path $directory '.disable'), '')
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data } | Should -Throw '*disabled*'
        { Test-AvmModuleMetadata @parameters } | Should -Throw '*disabled*'
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
    }

    It 'rejects a directory colliding with the metadata file even under WhatIf' {
        $fixture = New-MetadataFixture
        $null = New-Item -ItemType Directory -Path $fixture.MetadataPath
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -WhatIf } | Should -Throw '*must be a file*'
    }

    It 'rejects incorrect metadata casing consistently on every filesystem' {
        $fixture = New-MetadataFixture
        $incorrectPath = Join-Path $fixture.Root 'Metadata.json'
        [System.IO.File]::WriteAllText($incorrectPath, '{}')
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Issues[0].Code | Should -Be 'AVM_METADATA_CASE'
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -WhatIf } | Should -Throw '*exact casing*'
        [System.IO.File]::ReadAllText($incorrectPath) | Should -BeExactly '{}'
    }

    It 'writes strict UTF-8 without BOM, LF, and a trailing newline' {
        $fixture = New-MetadataFixture
        $parameters = $fixture.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.Changed | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($fixture.MetadataPath)
        $bytes[0] | Should -Be 123
        $bytes | Should -Not -Contain 13
        $bytes[-1] | Should -Be 10
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
    }

    It 'validates and plans under WhatIf without creating metadata or source files' {
        $fixture = New-MetadataFixture
        $parameters = $fixture.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource -WhatIf
        $result.Changed | Should -BeFalse
        $result.PlannedFiles | Should -Contain 'metadata.json'
        $result.PlannedFiles | Should -Contain 'main.metadata.tf'
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        @(Get-ChildItem -LiteralPath $fixture.Root -Force -File).Count | Should -Be 1
    }

    It 'preserves existing owner-authored metadata even when a seed changes' {
        $fixture = New-MetadataFixture
        Save-MetadataFixture -Fixture $fixture
        $before = [System.IO.File]::ReadAllText($fixture.MetadataPath)
        $fixture.Data.tier = 'open-source'
        $parameters = $fixture.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.Changed | Should -BeFalse
        $result.Metadata.tier | Should -Be 'maintained'
        [System.IO.File]::ReadAllText($fixture.MetadataPath) | Should -BeExactly $before
    }

    It 'rejects an invalid seed before writing anything' {
        $fixture = New-MetadataFixture
        $fixture.Data.Remove('owners')
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } | Should -Throw
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
    }

    It 'does not repair invalid existing metadata from an old seed' {
        $fixture = New-MetadataFixture
        [System.IO.File]::WriteAllText($fixture.MetadataPath, '{}')
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data } | Should -Throw
        [System.IO.File]::ReadAllText($fixture.MetadataPath) | Should -BeExactly '{}'
    }

    It 'accepts a strict JSON seed file' {
        $fixture = New-MetadataFixture
        $seedPath = Join-Path $TestDrive 'metadata-seed.json'
        [System.IO.File]::WriteAllText($seedPath, ($fixture.Data | ConvertTo-Json -Depth 20))
        $parameters = $fixture.Parameters
        (Initialize-AvmModuleMetadata @parameters -SeedPath $seedPath).Changed | Should -BeTrue
    }

    It 'wires only the scoped Bicep telemetry value and is idempotent' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $parameters = $fixture.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource
        $result.Changed | Should -BeTrue
        $source = [System.IO.File]::ReadAllText($fixture.SourcePath)
        $source | Should -Match ([regex]::Escape("loadJsonContent('metadata.json', '$.telemetryIdPrefix')"))
        $source | Should -Not -Match ([regex]::Escape("loadJsonContent('metadata.json')"))
        $source | Should -Match ([regex]::Escape("metadata name = 'Storage Accounts'"))
        $source | Should -Match ([regex]::Escape("metadata description = 'Deploys a Storage Account.'"))
        (Test-AvmModuleMetadata @parameters -CheckSource).Status | Should -Be 'pass'
        (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource).Changed | Should -BeFalse
        [System.IO.File]::ReadAllText($fixture.SourcePath) | Should -BeExactly $source
    }

    It 'owner and tier changes never rewrite Bicep source after initialization' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $parameters = $fixture.Parameters
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource
        $before = (Get-FileHash -LiteralPath $fixture.SourcePath).Hash
        $fixture.Data.tier = 'core'
        $fixture.Data.owners = @{ individuals = @(@{ githubHandle = 'new-owner' }) }
        Save-MetadataFixture -Fixture $fixture
        (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource).Changed | Should -BeFalse
        (Get-FileHash -LiteralPath $fixture.SourcePath).Hash | Should -Be $before
    }

    It 'fails a Bicep source mismatch before creating metadata' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $fixture.Data.telemetryIdPrefix = '46d3xbcp.res.different-prefix'
        $parameters = $fixture.Parameters
        $before = (Get-FileHash -LiteralPath $fixture.SourcePath).Hash
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } | Should -Throw
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        (Get-FileHash -LiteralPath $fixture.SourcePath).Hash | Should -Be $before
    }

    It 'preserves comments while wiring the real Bicep deployment rather than a commented copy' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $parameters = $fixture.Parameters
        $source = [System.IO.File]::ReadAllText($fixture.SourcePath)
        $source = $source.Replace("  name:", "  // deployment name`n  name:")
        $comment = @'
/*
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = if (enableTelemetry) {
  name: '46d3xbcp.res.storage-storageaccount.old-example'
}
*/
'@
        [System.IO.File]::WriteAllText($fixture.SourcePath, $comment + "`n" + $source)
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource
        $updated = [System.IO.File]::ReadAllText($fixture.SourcePath)
        $updated | Should -Match ([regex]::Escape($comment))
        $updated | Should -Match ([regex]::Escape("// deployment name`n  name: '" + '${avmTelemetryIdPrefix}'))
    }

    It 'requires a telemetry prefix for a utility that actually emits telemetry' {
        $fixture = New-MetadataFixture -Ecosystem bicep -ModuleType utility
        $fixture.Data.Remove('telemetryIdPrefix')
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } | Should -Throw '*emits telemetry*'
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        Save-MetadataFixture -Fixture $fixture
        (Test-AvmModuleMetadata @parameters -CheckSource).Status | Should -Be 'fail'
    }

    It 'writes native Terraform JSON locals for roots and children' {
        foreach ($child in @($false, $true)) {
            $fixture = New-MetadataFixture -ChildModule:$child
            $parameters = $fixture.Parameters
            $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource
            $result.Changed | Should -BeTrue
            $sourcePath = Join-Path $fixture.Root 'main.metadata.tf'
            $source = [System.IO.File]::ReadAllText($sourcePath)
            $source | Should -Match ([regex]::Escape('jsondecode(file("${path.module}/metadata.json"))'))
            $source | Should -Match 'avm_telemetry_id_prefix\s*=\s*local.avm_metadata.telemetryIdPrefix'
            if ($child) {
                $source | Should -Match ([regex]::Escape('jsondecode(file("${path.module}/../../metadata.json")).tier'))
                $result.Metadata.Contains('owners') | Should -BeFalse
                $result.Metadata.Contains('tier') | Should -BeFalse
            }
            else {
                $source | Should -Match 'avm_tier\s*=\s*local.avm_metadata.tier'
            }
            (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource).Changed | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.tf.json') | Should -BeFalse
            (Get-Content -LiteralPath $fixture.SourcePath -Raw) | Should -Match 'unrelated = true'
        }
    }

    It 'does not add a Terraform telemetry local to a utility without telemetry' {
        $fixture = New-MetadataFixture -ModuleType utility
        $fixture.Data.Remove('telemetryIdPrefix')
        $parameters = $fixture.Parameters
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource
        Get-Content -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') -Raw | Should -Not -Match 'telemetry'
    }

    It 'refuses a conflicting Terraform local before creating metadata' {
        $fixture = New-MetadataFixture
        [System.IO.File]::AppendAllText($fixture.SourcePath, "`nlocals {`n  avm_metadata = {}`n}`n")
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } | Should -Throw
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
    }

    It 'never overwrites an authored Terraform metadata reader' {
        $fixture = New-MetadataFixture
        $sourcePath = Join-Path $fixture.Root 'main.metadata.tf'
        [System.IO.File]::WriteAllText($sourcePath, 'locals { authored = true }')
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } | Should -Throw
        [System.IO.File]::ReadAllText($sourcePath) | Should -BeExactly 'locals { authored = true }'
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
    }

    It 'registers both metadata commands and exports only their public surface' {
        (Get-Command Test-AvmModuleMetadata -Module Avm.Authoring).Parameters.ContainsKey('SkipModuleVersionCheck') | Should -BeTrue
        (Get-Command Initialize-AvmModuleMetadata -Module Avm.Authoring).Parameters.ContainsKey('WhatIf') | Should -BeTrue
        Get-Command ConvertFrom-AvmMetadataJson -Module Avm.Authoring -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $registry = InModuleScope Avm.Authoring { Get-AvmVerbRegistry }
        ($registry | Where-Object { ($_.Path -join ' ') -eq 'metadata validate' }).Cmdlet | Should -Be 'Test-AvmModuleMetadata'
        ($registry | Where-Object { ($_.Path -join ' ') -eq 'metadata initialize' }).Cmdlet | Should -Be 'Initialize-AvmModuleMetadata'
    }
}
