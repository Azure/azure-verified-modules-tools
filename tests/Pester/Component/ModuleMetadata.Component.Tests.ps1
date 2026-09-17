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
            moduleDisplayName = 'Storage Accounts'
            moduleDescription = 'Deploys a Storage Account.'
            canonicalType     = $canonical
            telemetryIdPrefix = "$marker.$kind.storage-storageaccount"
        }
        if (-not $ChildModule) {
            $data.owners = @('azure-owner')
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
        $result.Metadata.Contains('schemaVersion') | Should -BeFalse
        $result.Metadata.Contains('tier') | Should -BeFalse
        $result.Metadata.Contains('owners') | Should -Be (-not $Child)
    }

    It 'accepts team-only ownership without storing personal names' {
        $fixture = New-MetadataFixture
        $fixture.Data.owners = @('@Azure/avm-core-modules', '@Other-org/team-name')
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
    }

    It 'initializes single-segment <ModuleType> metadata for <Ecosystem>, child=<Child>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('pattern', 'utility')) {
                foreach ($child in @($false, $true)) {
                    @{ Ecosystem = $ecosystem; ModuleType = $kind; Child = $child }
                }
            }
        }
    ) {
        param($Ecosystem, $ModuleType, $Child)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$Child
        $fixture.Data.canonicalType = if ($ModuleType -eq 'pattern') { 'alz' } else { 'naming' }
        if ($ModuleType -eq 'utility') {
            $fixture.Data.Remove('telemetryIdPrefix')
            if ($Ecosystem -eq 'bicep') {
                [System.IO.File]::WriteAllText($fixture.SourcePath, "metadata name = 'Storage Accounts'`nmetadata description = 'Deploys a Storage Account.'`n")
            }
        }
        $parameters = $fixture.Parameters
        $before = [System.IO.File]::ReadAllBytes($fixture.SourcePath)
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.PlannedFiles | Should -Be @('metadata.json')
        $result.Metadata.canonicalType | Should -BeExactly $fixture.Data.canonicalType
        $result.Metadata.Contains('owners') | Should -Be (-not $Child)
        $result.Metadata.Contains('telemetryIdPrefix') | Should -Be ($ModuleType -eq 'pattern')
        (Test-AvmModuleMetadata @parameters -CheckSource:($Ecosystem -eq 'bicep')).Status | Should -Be 'pass'
        (Get-AvmModuleMetadata @parameters).Metadata.canonicalType | Should -BeExactly $fixture.Data.canonicalType
        (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data).Changed | Should -BeFalse
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
    }

    It 'rejects empty or unsafe non-resource canonical types: <Case>' -TestCases @(
        @{ Case = 'empty'; Canonical = '' }
        @{ Case = 'whitespace'; Canonical = ' ' }
        @{ Case = 'uppercase'; Canonical = 'Naming' }
        @{ Case = 'underscore'; Canonical = 'naming_helper' }
        @{ Case = 'traversal'; Canonical = '../naming' }
        @{ Case = 'child traversal'; Canonical = 'naming/..' }
        @{ Case = 'absolute path'; Canonical = '/naming' }
        @{ Case = 'trailing slash'; Canonical = 'naming/' }
        @{ Case = 'empty segment'; Canonical = 'naming//child' }
        @{ Case = 'backslash'; Canonical = 'naming\child' }
    ) {
        param($Canonical)
        foreach ($kind in @('pattern', 'utility')) {
            $fixture = New-MetadataFixture -ModuleType $kind
            $fixture.Data.canonicalType = $Canonical
            $parameters = $fixture.Parameters
            $result = Test-AvmModuleMetadata @parameters -InputObject $fixture.Data
            $result.Status | Should -Be 'fail'
            $result.Issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
            { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data } | Should -Throw
            Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        }
    }

    It 'preserves many individual and team owners without an ownership limit' {
        $fixture = New-MetadataFixture
        $fixture.Data.owners = @('first-owner', '@Azure/team-one', 'second-owner', 'third-owner', '@Azure/team-two', 'fourth-owner')
        $parameters = $fixture.Parameters
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'pass'
        $result.Metadata.owners |
            Should -Be @('first-owner', '@Azure/team-one', 'second-owner', 'third-owner', '@Azure/team-two', 'fourth-owner')
    }

    It 'rejects invalid authored fields: <Case>' -TestCases @(
        @{ Case = 'removed tier'; Property = 'tier'; Value = 'core' }
        @{ Case = 'removed maintained tier'; Property = 'tier'; Value = 'maintained' }
        @{ Case = 'removed schemaVersion'; Property = 'schemaVersion'; Value = 1 }
        @{ Case = 'future schemaVersion'; Property = 'schemaVersion'; Value = 2 }
        @{ Case = 'missing reference'; Property = '$schema'; Remove = $true }
        @{ Case = 'foreign reference'; Property = '$schema'; Value = 'https://example.invalid/schema.json' }
        @{ Case = 'derived module type'; Property = 'moduleType'; Value = 'resource' }
        @{ Case = 'derived parent'; Property = 'parentModule'; Value = 'parent' }
        @{ Case = 'derived status'; Property = 'status'; Value = 'deprecated' }
        @{ Case = 'derived deprecation'; Property = 'deprecated'; Value = $true }
        @{ Case = 'empty description'; Property = 'moduleDescription'; Value = '' }
        @{ Case = 'whitespace name'; Property = 'moduleDisplayName'; Value = ' ' }
        @{ Case = 'wrong canonical kind'; Property = 'canonicalType'; Value = 'types/example' }
        @{ Case = 'single non-resource canonical'; Property = 'canonicalType'; Value = 'naming' }
        @{ Case = 'invalid canonical'; Property = 'canonicalType'; Value = 'Microsoft.Storage' }
        @{ Case = 'wrong ecosystem'; Property = 'telemetryIdPrefix'; Value = '46d3xbcp.res.storage-storageaccount' }
        @{ Case = 'wrong telemetry kind'; Property = 'telemetryIdPrefix'; Value = '46d3xtrf.ptn.storage-storageaccount' }
        @{ Case = 'missing telemetry'; Property = 'telemetryIdPrefix'; Remove = $true }
        @{ Case = 'missing owners'; Property = 'owners'; Remove = $true }
        @{ Case = 'legacy nested owners'; Property = 'owners'; Value = @{ individuals = @(@{ githubHandle = 'owner' }); team = '@Azure/team' } }
        @{ Case = 'owner object'; Property = 'owners'; Value = @(@{ githubHandle = 'owner' }) }
        @{ Case = 'owner PII'; Property = 'owners'; Value = @(@{ githubHandle = 'owner'; displayName = 'Personal Name' }) }
        @{ Case = 'scalar owners'; Property = 'owners'; Value = 'owner' }
        @{ Case = 'null owners'; Property = 'owners'; Value = $null }
        @{ Case = 'duplicate individual'; Property = 'owners'; Value = @('owner', 'owner') }
        @{ Case = 'duplicate team'; Property = 'owners'; Value = @('@Azure/team', '@Azure/team') }
        @{ Case = 'duplicate handle casing'; Property = 'owners'; Value = @('owner', 'Owner') }
        @{ Case = 'duplicate team casing'; Property = 'owners'; Value = @('@Azure/team', '@azure/team') }
        @{ Case = 'invalid team'; Property = 'owners'; Value = @('Azure/team') }
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

    It 'rejects invalid owner tokens: <Case>' -TestCases @(
        @{ Case = 'empty token'; Token = '' }
        @{ Case = 'whitespace'; Token = ' ' }
        @{ Case = 'personal name'; Token = 'Owner Name' }
        @{ Case = 'prefixed individual'; Token = '@owner' }
        @{ Case = 'individual underscore'; Token = 'owner_name' }
        @{ Case = 'individual leading hyphen'; Token = '-owner' }
        @{ Case = 'individual trailing hyphen'; Token = 'owner-' }
        @{ Case = 'individual consecutive hyphens'; Token = 'owner--name' }
        @{ Case = 'individual trailing newline'; Token = "owner`n" }
        @{ Case = 'overlong individual'; Token = ('a' * 40) }
        @{ Case = 'unqualified team'; Token = 'Azure/team' }
        @{ Case = 'missing organization'; Token = '@/team' }
        @{ Case = 'missing team'; Token = '@Azure/' }
        @{ Case = 'extra team segment'; Token = '@Azure/team/extra' }
        @{ Case = 'invalid organization'; Token = '@Azure_org/team' }
        @{ Case = 'organization leading hyphen'; Token = '@-Azure/team' }
        @{ Case = 'organization trailing hyphen'; Token = '@Azure-/team' }
        @{ Case = 'organization consecutive hyphens'; Token = '@Azure--org/team' }
        @{ Case = 'team uppercase slug'; Token = '@Azure/Team' }
        @{ Case = 'team underscore'; Token = '@Azure/team_name' }
        @{ Case = 'team leading hyphen'; Token = '@Azure/-team' }
        @{ Case = 'team trailing hyphen'; Token = '@Azure/team-' }
        @{ Case = 'team consecutive hyphens'; Token = '@Azure/team--name' }
        @{ Case = 'team trailing newline'; Token = "@Azure/team`n" }
        @{ Case = 'null token'; Token = $null }
        @{ Case = 'numeric token'; Token = 123 }
        @{ Case = 'nested array'; Token = @('owner') }
    ) {
        param($Token)
        $fixture = New-MetadataFixture
        $fixture.Data.owners = , $Token
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
    }

    It 'accepts the existing individual handle length boundaries and qualified team syntax' {
        $fixture = New-MetadataFixture
        $fixture.Data.owners = @('a', ('b' * 39), 'Owner-One', '@Example-org/a-team', '@3Org/1-team')
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'pass'
        $result.Metadata.owners | Should -Be $fixture.Data.owners
    }

    It 'accepts one-letter and underscore ARM child type segments: <CanonicalType>' -TestCases @(
        @{ CanonicalType = 'Microsoft.Storage/storageAccounts/a' }
        @{ CanonicalType = 'Microsoft.Example/a_b/c' }
    ) {
        param($CanonicalType)
        $fixture = New-MetadataFixture -ChildModule
        $fixture.Data.canonicalType = $CanonicalType
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
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

    It 'preserves single-segment pattern telemetry requirements for <Ecosystem>, child=<Child>, published=<Published>' -TestCases @(
        @{ Ecosystem = 'terraform'; Child = $false; Published = $false; Status = 'fail' }
        @{ Ecosystem = 'terraform'; Child = $true; Published = $false; Status = 'fail' }
        @{ Ecosystem = 'bicep'; Child = $false; Published = $false; Status = 'fail' }
        @{ Ecosystem = 'bicep'; Child = $true; Published = $false; Status = 'pass' }
        @{ Ecosystem = 'bicep'; Child = $true; Published = $true; Status = 'fail' }
    ) {
        param($Ecosystem, $Child, $Published, $Status)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem -ModuleType pattern -ChildModule:$Child
        $fixture.Data.canonicalType = 'alz'
        $fixture.Data.Remove('telemetryIdPrefix')
        if ($Ecosystem -eq 'bicep') {
            [System.IO.File]::WriteAllText($fixture.SourcePath, "metadata name = 'Storage Accounts'`nmetadata description = 'Deploys a Storage Account.'`n")
        }
        if ($Published) {
            [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'version.json'), '{"version":"1.0.0"}')
        }
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.Status | Should -Be $Status
        if ($Status -eq 'fail') {
            $result.Issues[0].Code | Should -Be 'AVM_METADATA_TELEMETRY'
        }
    }

    It 'allows empty owners without inventing a team or person' {
        $fixture = New-MetadataFixture
        $fixture.Data.owners = @()
        $parameters = $fixture.Parameters
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'pass'
        ($result.Metadata.owners -is [array]) | Should -BeTrue
        $result.Metadata.owners | Should -HaveCount 0
    }

    It 'omits telemetry only for Bicep children that are unpublished and uninstrumented' {
        $fixture = New-MetadataFixture -Ecosystem bicep -ChildModule
        $fixture.Data.Remove('telemetryIdPrefix')
        [System.IO.File]::WriteAllText($fixture.SourcePath, "metadata name = 'Storage Accounts'`nmetadata description = 'Deploys a Storage Account.'`n")
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters -CheckSource).Status | Should -Be 'pass'
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'version.json'), '{"version":"1.0.0"}')
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
    }

    It 'accepts existing underscore telemetry identifiers without changing their value' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $fixture.Data.telemetryIdPrefix = '46d3xbcp.res.authz-policyassignment_mgscope'
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'pass'
        $result.Metadata.telemetryIdPrefix | Should -BeExactly $fixture.Data.telemetryIdPrefix
    }

    It 'limits the exact legacy Resource Graph prefix to its existing Bicep resource identity' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $fixture.Data.telemetryIdPrefix = '46d3xbcp.resourcegraph-query'
        $fixture.Data.canonicalType = 'Microsoft.ResourceGraph/queries'
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
        $fixture.Data.canonicalType = 'Microsoft.Storage/storageAccounts'
        Save-MetadataFixture -Fixture $fixture
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
    }

    It 'does not confuse the reduced child shape with a root' {
        $fixture = New-MetadataFixture -ChildModule
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $parameters.ChildModule = $false
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'fail'
    }

    It 'rejects root-only or removed properties on a child: <Property>' -TestCases @(
        @{ Property = 'owners'; Value = @() }
        @{ Property = 'tier'; Value = 'core' }
        @{ Property = 'schemaVersion'; Value = 1 }
        @{ Property = 'alternativeNames'; Value = @('Storage') }
        @{ Property = 'comments'; Value = '' }
    ) {
        param($Property, $Value)
        $fixture = New-MetadataFixture -ChildModule
        $fixture.Data[$Property] = $Value
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
    }

    It 'requires the versioned schema reference on a child' {
        $fixture = New-MetadataFixture -ChildModule
        $fixture.Data.Remove('$schema')
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
    }

    It 'reports missing or malformed metadata rather than passing or falling back' {
        $fixture = New-MetadataFixture
        $parameters = $fixture.Parameters
        (Test-AvmModuleMetadata @parameters).Issues[0].Code | Should -Be 'AVM_METADATA_MISSING'
        [System.IO.File]::WriteAllText($fixture.MetadataPath, '{"owners":[],}')
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

Describe 'Component: permanent metadata reader' -Tag Component {
    It 'reads existing <Ecosystem> metadata without changing source or metadata files' -TestCases @(
        @{ Ecosystem = 'bicep' }
        @{ Ecosystem = 'terraform' }
    ) {
        param($Ecosystem)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem
        Save-MetadataFixture -Fixture $fixture
        $parameters = $fixture.Parameters
        $before = [System.IO.File]::ReadAllBytes($fixture.MetadataPath)
        $sourceBefore = [System.IO.File]::ReadAllBytes($fixture.SourcePath)
        $result = Get-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'pass'
        $result.Metadata.canonicalType | Should -BeExactly 'Microsoft.Storage/storageAccounts'
        [System.IO.File]::ReadAllBytes($fixture.MetadataPath) | Should -Be $before
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $sourceBefore
    }

    It 'reports a missing file without deriving values from source or indexes' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'repository-metadata.csv'), 'invalid,ignored,index')
        $parameters = $fixture.Parameters
        $result = Get-AvmModuleMetadata @parameters
        $result.Status | Should -Be 'fail'
        $result.Issues[0].Code | Should -Be 'AVM_METADATA_MISSING'
        $result.Metadata | Should -BeNullOrEmpty
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
    }

    It 'has no migration parameters or packaged conversion helpers' {
        $command = Get-Command Get-AvmModuleMetadata -Module Avm.Authoring
        foreach ($parameterName in @('ModuleId', 'LegacyRecord', 'Override', 'OwnerGitHubHandle', 'InputObject')) {
            $command.Parameters.ContainsKey($parameterName) | Should -BeFalse
        }
        InModuleScope Avm.Authoring {
            foreach ($name in @('ConvertTo-AvmModuleMetadata', 'Get-AvmLegacyMetadataValue', 'Get-AvmMetadataSource', 'Get-AvmMetadataBackfillCandidate')) {
                Get-Command -Name $name -Module Avm.Authoring -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }
    }

    It 'validates supplied values without reading or overwriting an existing file: <Case>' -TestCases @(
        @{ Case = 'invalid owner token'; Property = 'owners'; Value = @('@invalid-user') }
        @{ Case = 'nested owners'; Property = 'owners'; Value = @{ individuals = @(@{ githubHandle = 'owner' }) } }
        @{ Case = 'removed tier'; Property = 'tier'; Value = 'core' }
        @{ Case = 'removed schemaVersion'; Property = 'schemaVersion'; Value = 1 }
    ) {
        param($Property, $Value)
        $fixture = New-MetadataFixture
        [System.IO.File]::WriteAllText($fixture.MetadataPath, 'invalid existing JSON')
        $parameters = $fixture.Parameters
        $result = Test-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.Status | Should -Be 'pass'
        [System.IO.File]::ReadAllText($fixture.MetadataPath) | Should -BeExactly 'invalid existing JSON'
        $fixture.Data[$Property] = $Value
        $invalid = Test-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $invalid.Status | Should -Be 'fail'
        $invalid.Issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
        [System.IO.File]::ReadAllText($fixture.MetadataPath) | Should -BeExactly 'invalid existing JSON'
    }

    It 'works from an isolated module copy with no repository-management migration directory' {
        $standalone = Join-Path $TestDrive 'standalone-package'
        $null = New-Item -ItemType Directory -Path $standalone
        Copy-Item -LiteralPath $moduleRoot -Destination $standalone -Recurse
        $manifest = Join-Path $standalone 'Avm.Authoring' 'Avm.Authoring.psd1'
        $fixture = New-MetadataFixture
        $parameters = $fixture.Parameters
        try {
            Remove-Module Avm.Authoring -Force
            Import-Module $manifest -Force
            (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data).Changed | Should -BeTrue
            (Get-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
            (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
            Test-Path -LiteralPath (Join-Path $standalone 'repository-management') | Should -BeFalse
        }
        finally {
            Remove-Module Avm.Authoring -Force
            Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        }
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

    It 'validates and plans <Ecosystem> under WhatIf without changing files' -TestCases @(
        @{ Ecosystem = 'terraform'; UpdateSource = $false; PlannedFiles = @('metadata.json') }
        @{ Ecosystem = 'bicep'; UpdateSource = $true; PlannedFiles = @('metadata.json', 'main.bicep') }
    ) {
        param($Ecosystem, $UpdateSource, $PlannedFiles)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem
        $parameters = $fixture.Parameters
        $before = [System.IO.File]::ReadAllBytes($fixture.SourcePath)
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource:$UpdateSource -WhatIf
        $result.Changed | Should -BeFalse
        $result.PlannedFiles | Should -Be $PlannedFiles
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $before
        @(Get-ChildItem -LiteralPath $fixture.Root -Force -File).Count | Should -Be 1
    }

    It 'preserves existing owner-authored metadata even when proposed values change' {
        $fixture = New-MetadataFixture
        Save-MetadataFixture -Fixture $fixture
        $before = [System.IO.File]::ReadAllText($fixture.MetadataPath)
        $fixture.Data.owners = @('@invalid-user')
        $parameters = $fixture.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.Changed | Should -BeFalse
        $result.Metadata.owners | Should -Be @('azure-owner')
        [System.IO.File]::ReadAllText($fixture.MetadataPath) | Should -BeExactly $before
    }

    It 'does not rewrite <Ecosystem> source during metadata-only initialization and edits' -TestCases @(
        @{ Ecosystem = 'bicep' }
        @{ Ecosystem = 'terraform' }
    ) {
        param($Ecosystem)
        $fixture = New-MetadataFixture -Ecosystem $Ecosystem
        $parameters = $fixture.Parameters
        $before = [System.IO.File]::ReadAllBytes($fixture.SourcePath)
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.PlannedFiles | Should -Be @('metadata.json')
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $before
        $fixture.Data.owners = @('new-owner', '@Azure/new-team')
        $fixture.Data.canonicalType = 'Microsoft.Storage/storageAccounts/a'
        Save-MetadataFixture -Fixture $fixture
        (Get-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
        (Test-AvmModuleMetadata @parameters).Status | Should -Be 'pass'
        (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data).Changed | Should -BeFalse
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $fixture.Root -Force -File) | Should -HaveCount 2
    }

    It 'rejects invalid metadata values before writing anything: <Case>' -TestCases @(
        @{ Case = 'missing owners'; Property = 'owners'; Remove = $true }
        @{ Case = 'nested owners'; Property = 'owners'; Value = @{ individuals = @() } }
        @{ Case = 'owner object'; Property = 'owners'; Value = @(@{ githubHandle = 'owner' }) }
        @{ Case = 'removed tier'; Property = 'tier'; Value = 'core' }
        @{ Case = 'removed schemaVersion'; Property = 'schemaVersion'; Value = 1 }
    ) {
        param($Property, $Value, $Remove)
        $fixture = New-MetadataFixture
        if ($Remove) {
            $fixture.Data.Remove($Property)
        }
        else {
            $fixture.Data[$Property] = $Value
        }
        $parameters = $fixture.Parameters
        $before = [System.IO.File]::ReadAllBytes($fixture.SourcePath)
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data } | Should -Throw
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $before
    }

    It 'does not replace invalid existing metadata with generated values' {
        $fixture = New-MetadataFixture
        [System.IO.File]::WriteAllText($fixture.MetadataPath, '{}')
        $parameters = $fixture.Parameters
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data } | Should -Throw
        [System.IO.File]::ReadAllText($fixture.MetadataPath) | Should -BeExactly '{}'
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

    It 'owner and canonical type changes never rewrite Bicep source after initialization' {
        $fixture = New-MetadataFixture -Ecosystem bicep
        $parameters = $fixture.Parameters
        $null = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource
        $before = (Get-FileHash -LiteralPath $fixture.SourcePath).Hash
        $fixture.Data.canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        $fixture.Data.owners = @('new-owner', '@Azure/new-team')
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
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } | Should -Throw '*requires telemetryIdPrefix*'
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        Save-MetadataFixture -Fixture $fixture
        (Test-AvmModuleMetadata @parameters -CheckSource).Status | Should -Be 'fail'
    }

    It 'initializes Terraform roots and children without generating source readers' {
        foreach ($child in @($false, $true)) {
            $fixture = New-MetadataFixture -ChildModule:$child
            $parameters = $fixture.Parameters
            $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
            $result.Changed | Should -BeTrue
            $result.PlannedFiles | Should -Be @('metadata.json')
            Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
            $result.Metadata.Contains('tier') | Should -BeFalse
            $result.Metadata.Contains('schemaVersion') | Should -BeFalse
            if ($child) {
                $result.Metadata.Contains('owners') | Should -BeFalse
            }
            (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data).Changed | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.Root 'metadata.tf.json') | Should -BeFalse
            (Get-Content -LiteralPath $fixture.SourcePath -Raw) | Should -Match 'unrelated = true'
        }
    }

    It 'does not add a Terraform telemetry local to a utility without telemetry' {
        $fixture = New-MetadataFixture -ModuleType utility
        $fixture.Data.Remove('telemetryIdPrefix')
        $parameters = $fixture.Parameters
        $result = Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data
        $result.PlannedFiles | Should -Be @('metadata.json')
        Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
    }

    It 'rejects Terraform UpdateSource before writes for child=<Child> and WhatIf=<Preview>' -TestCases @(
        @{ Child = $false; Preview = $false }
        @{ Child = $false; Preview = $true }
        @{ Child = $true; Preview = $false }
        @{ Child = $true; Preview = $true }
    ) {
        param($Child, $Preview)
        $fixture = New-MetadataFixture -ChildModule:$Child
        $parameters = $fixture.Parameters
        $before = [System.IO.File]::ReadAllBytes($fixture.SourcePath)
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource -WhatIf:$Preview } |
            Should -Throw '*Terraform -UpdateSource is not supported*'
        Test-Path -LiteralPath $fixture.MetadataPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($fixture.SourcePath) | Should -Be $before
    }

    It 'never overwrites an authored Terraform metadata reader' {
        $fixture = New-MetadataFixture
        $sourcePath = Join-Path $fixture.Root 'main.metadata.tf'
        [System.IO.File]::WriteAllText($sourcePath, 'locals { authored = true }')
        $parameters = $fixture.Parameters
        (Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data).Changed | Should -BeTrue
        $before = [System.IO.File]::ReadAllBytes($fixture.MetadataPath)
        { Initialize-AvmModuleMetadata @parameters -InputObject $fixture.Data -UpdateSource } |
            Should -Throw '*Terraform -UpdateSource is not supported*'
        [System.IO.File]::ReadAllText($sourcePath) | Should -BeExactly 'locals { authored = true }'
        [System.IO.File]::ReadAllBytes($fixture.MetadataPath) | Should -Be $before
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
