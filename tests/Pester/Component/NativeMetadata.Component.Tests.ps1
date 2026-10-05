#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:metadataFixture = Join-Path $repoRoot 'tests' 'fixtures' 'modules' 'bicep-storage' `
        'avm' 'res' 'storage' 'storage-account' 'metadata.json'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: native shared metadata assertions' -Tag Component {
    It 'disables dependency name checks without suppressing validation warnings globally' {
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:metadataFixture } {
            param($Fixture)
            Mock Import-Module {
                if (-not $DisableNameChecking) { Write-Warning 'Pester dependency name-check warning.' }
            } -ParameterFilter { $Name -eq 'Pester' }
            $inputData = Get-AvmMetadataValidationInput -Json (Get-Content -LiteralPath $Fixture -Raw) `
                -Ecosystem bicep -ModuleType resource
            $warnings = @()
            $result = Invoke-AvmMetadataValidation -Validations @($inputData) -WarningVariable warnings
            $result.Tests | Should -HaveCount 6
            $result.Issues | Should -HaveCount 0
            @($warnings) | Should -HaveCount 0
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Pester' -and $DisableNameChecking -and $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'runs the same six independent requirements for both ecosystems in one suite' {
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:metadataFixture } {
            param($Fixture)
            $json = Get-Content -LiteralPath $Fixture -Raw
            $inputs = @(
                Get-AvmMetadataValidationInput -Json $json -Ecosystem bicep -ModuleType resource -Path bicep
                Get-AvmMetadataValidationInput -Json $json.Replace('46d3xbcp', '46d3xtrf') `
                    -Ecosystem terraform -ModuleType resource -Path terraform
            )
            $result = Invoke-AvmMetadataValidation -Validations $inputs
            $result.Issues | Should -HaveCount 0
            $result.Tests | Should -HaveCount 12
            @($result.Tests | Where-Object Result -NE 'Passed') | Should -HaveCount 0
            foreach ($ecosystem in @('bicep', 'terraform')) {
                $names = @($result.Tests | Where-Object Name -Like "Module metadata: $ecosystem.*" | ForEach-Object Name)
                $names | Should -HaveCount 6
                $names | Should -Contain "Module metadata: $ecosystem.matches the packaged root or child schema"
                $names | Should -Contain "Module metadata: $ecosystem.identifies the requested module kind"
                $names | Should -Contain "Module metadata: $ecosystem.uses the ecosystem and module-kind telemetry marker"
                $names | Should -Contain "Module metadata: $ecosystem.does not repeat the current telemetry prefix in its history"
                $names | Should -Contain "Module metadata: $ecosystem.supplies telemetry when required for this scope"
                $names | Should -Contain "Module metadata: $ecosystem.has unique owner handles ignoring case"
            }
        }
    }

    It 'shares the <Constraint> constraint between native assertions and internal <Ecosystem> guards' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($constraint in @('shape', 'kind', 'marker', 'history', 'required', 'owners')) {
                @{ Ecosystem = $ecosystem; Constraint = $constraint }
            }
        }
    ) {
        param($Ecosystem, $Constraint)
        InModuleScope Avm.Authoring -Parameters @{
            Fixture = $script:metadataFixture; Ecosystem = $Ecosystem; Constraint = $Constraint
        } {
            param($Fixture, $Ecosystem, $Constraint)
            $metadata = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json -AsHashtable
            if ($Ecosystem -eq 'terraform') {
                $metadata.telemetryIdPrefix = $metadata.telemetryIdPrefix.Replace('46d3xbcp', '46d3xtrf')
            }
            switch ($Constraint) {
                'shape' { $metadata.moduleDisplayName = '' }
                'kind' { $metadata.canonicalType = 'types/mock' }
                'marker' { $metadata.telemetryIdPrefix = '46d3xtrf.ptn.1234567' }
                'history' { $metadata.alternativeTelemetryIdPrefixes = @($metadata.telemetryIdPrefix) }
                'required' { $metadata.Remove('telemetryIdPrefix'); $metadata.Remove('owners') }
                'owners' { $metadata.owners = @('owner', 'OWNER') }
            }
            $json = ConvertTo-Json -InputObject $metadata -Depth 30
            $inputData = Get-AvmMetadataValidationInput -Json $json -Ecosystem $Ecosystem -ModuleType resource `
                -ChildModule:($Constraint -eq 'required') -TelemetryRequired $true
            $native = Invoke-AvmMetadataValidation -Validations @($inputData)
            $guard = Test-AvmMetadataContent -Json $json -Ecosystem $Ecosystem -ModuleType resource `
                -ChildModule:($Constraint -eq 'required') -TelemetryRequired $true
            $native.Issues | Should -HaveCount 1
            $guard.Issues | Should -HaveCount 1
            $native.Issues[0].Code | Should -Be $guard.Issues[0].Code
            $expected = switch ($Constraint) {
                'shape' { 'AVM_METADATA_SCHEMA' }
                'kind' { 'AVM_METADATA_KIND' }
                'owners' { 'AVM_METADATA_OWNER' }
                default { 'AVM_METADATA_TELEMETRY' }
            }
            $native.Issues[0].Code | Should -Be $expected
            @($native.Tests | Where-Object Result -EQ 'Failed') | Should -HaveCount 1
        }
    }

    It 'uses native assertions for both file and InputObject entry points without the internal guard' {
        $root = Join-Path $TestDrive 'public-metadata'
        $null = New-Item -ItemType Directory -Path $root
        Copy-Item -LiteralPath $script:metadataFixture -Destination (Join-Path $root 'metadata.json')
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Mock Test-AvmMetadataContent { throw 'Explicit validation must run the native suite.' }
            $metadata = Get-Content -LiteralPath (Join-Path $Root 'metadata.json') -Raw | ConvertFrom-Json -AsHashtable
            $file = Test-AvmModuleMetadata -Path $Root -Ecosystem bicep -ModuleType resource -SkipModuleVersionCheck
            $supplied = Test-AvmModuleMetadata -Path $Root -InputObject $metadata `
                -Ecosystem bicep -ModuleType resource -SkipModuleVersionCheck
            $file.Status | Should -Be 'pass'
            $supplied.Status | Should -Be 'pass'
            Should -Invoke Test-AvmMetadataContent -Times 0
        }
    }

    It 'does not report success when composition discovers no metadata scopes' {
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-AvmMetadataScope { @() }
            $result = Test-AvmMetadataModules -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            $result.Status | Should -Be 'fail'
            $result.Issues.Code | Should -Contain 'AVM_METADATA_SCOPE'
        }
    }

    It 'fails closed for <Failure> native framework execution' -TestCases @(
        @{ Failure = 'empty'; Passed = 0; Total = 0; Containers = 0; Blocks = 0 }
        @{ Failure = 'incomplete'; Passed = 5; Total = 5; Containers = 0; Blocks = 0 }
        @{ Failure = 'skipped'; Passed = 5; Total = 6; Containers = 0; Blocks = 0 }
        @{ Failure = 'container crash'; Passed = 6; Total = 6; Containers = 1; Blocks = 0 }
        @{ Failure = 'setup crash'; Passed = 6; Total = 6; Containers = 0; Blocks = 1 }
    ) {
        param($Passed, $Total, $Containers, $Blocks)
        InModuleScope Avm.Authoring -Parameters @{
            Fixture = $script:metadataFixture; Passed = $Passed; Total = $Total; Containers = $Containers; Blocks = $Blocks
        } {
            param($Fixture, $Passed, $Total, $Containers, $Blocks)
            Mock Invoke-Pester {
                [pscustomobject]@{
                    Tests = @(); TotalCount = $Total; PassedCount = $Passed; FailedCount = 0
                    FailedContainersCount = $Containers; FailedBlocksCount = $Blocks
                }
            }
            $inputData = Get-AvmMetadataValidationInput -Json (Get-Content -LiteralPath $Fixture -Raw) `
                -Ecosystem bicep -ModuleType resource
            $result = Invoke-AvmMetadataValidation -Validations @($inputData)
            $result.Issues.Code | Should -Contain 'AVM_METADATA_SUITE'
        }
    }
}
