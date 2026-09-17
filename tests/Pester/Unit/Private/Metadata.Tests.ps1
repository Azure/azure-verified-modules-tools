#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform metadata source wiring' {
    It 'rejects UpdateSource before version checks or filesystem access with WhatIf=<Preview>' -TestCases @(
        @{ Preview = $false }
        @{ Preview = $true }
    ) {
        param($Preview)
        InModuleScope Avm.Authoring -Parameters @{ Preview = $Preview } {
            param($Preview)
            Mock Test-AvmModuleVersion {}
            Mock Test-AvmDisableSentinel {}
            Mock Test-Path {}
            Mock Get-AvmMetadataSourcePlan {}
            { Initialize-AvmModuleMetadata -InputObject @{} -Ecosystem terraform -ModuleType resource -UpdateSource -WhatIf:$Preview } |
                Should -Throw '*Terraform -UpdateSource is not supported*'
            Should -Invoke Test-AvmModuleVersion -Exactly 0
            Should -Invoke Test-AvmDisableSentinel -Exactly 0
            Should -Invoke Test-Path -Exactly 0
            Should -Invoke Get-AvmMetadataSourcePlan -Exactly 0
        }
    }
}

Describe 'Strict metadata JSON' {
    It 'preserves a JSON object and arrays without evaluating values' {
        InModuleScope Avm.Authoring {
            $data = ConvertFrom-AvmMetadataJson -Json '{"owners":["azure-owner","@Azure/team-name"],"comments":"$(throw 1)"}'
            $data.owners | Should -Be @('azure-owner', '@Azure/team-name')
            $data.comments | Should -BeExactly '$(throw 1)'
        }
    }

    It 'preserves ISO-looking JSON strings and empty arrays without date or null coercion' {
        InModuleScope Avm.Authoring {
            $data = ConvertFrom-AvmMetadataJson -Json '{"moduleDescription":"2024-07-01T00:30:00Z","owners":[],"nested":{"items":[]},"values":[null,true,1,"2024-07-01T00:30:00Z"]}'
            $data.moduleDescription | Should -BeOfType ([string])
            $data.moduleDescription | Should -BeExactly '2024-07-01T00:30:00Z'
            ($data.owners -is [array]) | Should -BeTrue
            $data.owners.Count | Should -Be 0
            ($data.nested.items -is [array]) | Should -BeTrue
            $data.nested.items.Count | Should -Be 0
            $data.values.Count | Should -Be 4
            $data.values[3] | Should -BeOfType ([string])
        }
    }

    It 'rejects ambiguous or non-JSON content: <Case>' -TestCases @(
        @{ Case = 'comment'; Json = '{"a":1 /* comment */}' }
        @{ Case = 'trailing comma'; Json = '{"a":1,}' }
        @{ Case = 'duplicate root key'; Json = '{"a":1,"a":2}' }
        @{ Case = 'duplicate nested key'; Json = '{"a":[{"b":1,"b":2}]}' }
        @{ Case = 'array root'; Json = '[{"a":1}]' }
        @{ Case = 'null root'; Json = 'null' }
        @{ Case = 'empty document'; Json = '' }
    ) {
        param($Json)
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            { ConvertFrom-AvmMetadataJson -Json $Json } | Should -Throw
        }
    }
}

Describe 'Metadata owner uniqueness' {
    It 'compares all root owner strings without regard to case: <Case>' -TestCases @(
        @{ Case = 'unowned root'; Owners = @(); DuplicateCount = 0 }
        @{ Case = 'mixed individuals and teams'; Owners = @('owner-one', 'Owner-Two', '@Azure/team-one', '@Azure/team-two'); DuplicateCount = 0 }
        @{ Case = 'individual casing'; Owners = @('owner-one', 'OWNER-ONE'); DuplicateCount = 1 }
        @{ Case = 'team organization casing'; Owners = @('@Azure/team-one', '@azure/team-one'); DuplicateCount = 1 }
        @{ Case = 'duplicates across a mixed list'; Owners = @('owner-one', '@Azure/team-one', 'OWNER-ONE', '@azure/team-one'); DuplicateCount = 2 }
    ) {
        param($Owners, $DuplicateCount)
        InModuleScope Avm.Authoring -Parameters @{ Owners = $Owners; DuplicateCount = $DuplicateCount } {
            param($Owners, $DuplicateCount)
            Mock Get-Content { '{"oneOf":[]}' }
            Mock Test-Json { $true }
            $json = @{
                canonicalType = 'Microsoft.Storage/storageAccounts'
                telemetryIdPrefix = '46d3xtrf.res.storage-account'
                owners = $Owners
            } | ConvertTo-Json -Depth 20

            $result = Test-AvmMetadataContent -Json $json -Ecosystem terraform -ModuleType resource
            $result.Issues | Should -HaveCount $DuplicateCount
            foreach ($issue in $result.Issues) {
                $issue.Code | Should -Be 'AVM_METADATA_OWNER'
            }
        }
    }

    It 'does not read an owners property from reduced child metadata' {
        InModuleScope Avm.Authoring {
            Mock Get-Content { '{"oneOf":[]}' }
            Mock Test-Json { $true }
            $json = '{"canonicalType":"Microsoft.Storage/storageAccounts/a","telemetryIdPrefix":"46d3xtrf.res.storage-child"}'
            $result = Test-AvmMetadataContent -Json $json -Ecosystem terraform -ModuleType resource -ChildModule
            $result.Issues | Should -HaveCount 0
            $result.Metadata.Contains('owners') | Should -BeFalse
        }
    }
}

Describe 'Bicep literal metadata reader' {
    It 'reads literals while ignoring comments and decoy strings' {
        InModuleScope Avm.Authoring {
            $source = @'
/*
metadata name = 'wrong'
*/
// metadata description = 'wrong'
var example = '''
metadata name = 'also wrong'
'''
metadata name = 'Storage Accounts'
metadata description = 'Deploys a Storage Account.' // source description
'@
            $values = Get-AvmBicepMetadataLiteral -Source $source
            $values.name | Should -BeExactly 'Storage Accounts'
            $values.description | Should -BeExactly 'Deploys a Storage Account.'
        }
    }

    It 'decodes Bicep escapes and keeps escaped interpolation literal' {
        InModuleScope Avm.Authoring {
            $source = @'
metadata name = 'Owner\'s \u{41}ccount'
metadata description = 'Literal \${value} and \\ path\nnext line'
'@
            $values = Get-AvmBicepMetadataLiteral -Source $source
            $values.name | Should -BeExactly "Owner's Account"
            $values.description | Should -BeExactly ('Literal ${value} and \ path' + "`nnext line")
        }
    }

    It 'reads a multiline literal without its opening newline' {
        InModuleScope Avm.Authoring {
            $source = "metadata name = 'Account'`nmetadata description = '''`nFirst line.`nSecond line.`n'''`n"
            $values = Get-AvmBicepMetadataLiteral -Source $source
            $values.description | Should -BeExactly "First line.`nSecond line.`n"
        }
    }

    It 'rejects a non-literal, missing, duplicate, or interpolated declaration: <Case>' -TestCases @(
        @{ Case = 'expression'; Source = "metadata name = 'Account'`nmetadata description = concat('first', 'second')" }
        @{ Case = 'missing'; Source = "metadata name = 'Account'" }
        @{ Case = 'duplicate'; Source = "metadata name = 'A'`nmetadata name = 'B'`nmetadata description = 'C'" }
        @{ Case = 'interpolation'; Source = 'metadata name = ''${name}''' + "`nmetadata description = 'D'" }
        @{ Case = 'trailing expression'; Source = "metadata name = 'A' + 'B'`nmetadata description = 'D'" }
        @{ Case = 'invalid escape'; Source = "metadata name = '\q'`nmetadata description = 'D'" }
    ) {
        param($Source)
        InModuleScope Avm.Authoring -Parameters @{ Source = $Source } {
            param($Source)
            { Get-AvmBicepMetadataLiteral -Source $Source } | Should -Throw
        }
    }
}

Describe 'Metadata ARM resource classification' {
    It 'classifies the complete case-sensitive canonical value <Canonical>' -TestCases @(
        @{ Canonical = 'Oracle.Database/cloudExadataInfrastructures'; Expected = $true }
        @{ Canonical = 'Oracle.Database/cloudVmClusters'; Expected = $true }
        @{ Canonical = 'Oracle.Database/autonomousDatabases'; Expected = $true }
        @{ Canonical = 'Microsoft.Storage/storageAccounts'; Expected = $true }
        @{ Canonical = 'Microsoft.Network/dnsZones/A'; Expected = $true }
        @{ Canonical = 'Microsoft.Example/a_b/c'; Expected = $true }
        @{ Canonical = 'naming'; Expected = $false }
        @{ Canonical = 'lz/sub-vending'; Expected = $false }
        @{ Canonical = ''; Expected = $false }
        @{ Canonical = 'Oracle.Database'; Expected = $false }
        @{ Canonical = 'oracle.Database/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.database/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.Other/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.DatabaseExtra/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.Database.Extra/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Contoso.Database/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Microsoft.Oracle.Database/cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.Database//cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.Database/1cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.Database/cloud-vm-clusters'; Expected = $false }
        @{ Canonical = 'Oracle.Database/cloudVmClusters/'; Expected = $false }
        @{ Canonical = 'Oracle.Database/cloudVmClusters/../autonomousDatabases'; Expected = $false }
        @{ Canonical = 'Oracle.Database\cloudVmClusters'; Expected = $false }
        @{ Canonical = 'Oracle.Database/cloudVmClusters@2025-09-01'; Expected = $false }
        @{ Canonical = 'Microsoft.Storage/storageAccounts/Microsoft.Insights/diagnosticSettings'; Expected = $false }
        @{ Canonical = 'Oracle.Database/cloudVmClusters/Microsoft.Insights/diagnosticSettings'; Expected = $false }
    ) {
        param($Canonical, $Expected)
        InModuleScope Avm.Authoring -Parameters @{ Canonical = $Canonical; Expected = $Expected } {
            param($Canonical, $Expected)
            Test-AvmMetadataResourceType -CanonicalType $Canonical | Should -Be $Expected
        }
    }
}

Describe 'Metadata module identity' {
    It 'recognizes Oracle metadata without path, scope, Git, or telemetry identity: <Ecosystem>, <Canonical>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($canonical in @(
                    'Oracle.Database/cloudExadataInfrastructures',
                    'Oracle.Database/cloudVmClusters',
                    'Oracle.Database/autonomousDatabases'
                )) {
                @{ Ecosystem = $ecosystem; Canonical = $canonical }
            }
        }
    ) {
        param($Ecosystem, $Canonical)
        InModuleScope Avm.Authoring -Parameters @{ Ecosystem = $Ecosystem; Canonical = $Canonical } {
            param($Ecosystem, $Canonical)
            $context = [pscustomobject]@{ Root = Join-Path $TestDrive 'renamed'; Ecosystem = $Ecosystem }
            Mock Test-Path { $false }
            Mock Invoke-AvmProcess { throw 'Fallback discovery must not run a subprocess.' }
            Get-AvmMetadataModuleType -Context $context -Path $context.Root -Metadata @{ canonicalType = $Canonical } |
                Should -Be 'resource'
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'does not infer resource identity from a malformed namespace prefix: <Canonical>' -TestCases @(
        @{ Canonical = 'Microsoft.Storage' }
        @{ Canonical = 'Oracle.Database' }
        @{ Canonical = 'Oracle.Other/cloudVmClusters' }
        @{ Canonical = 'Microsoft.Storage/storageAccounts/Microsoft.Insights/diagnosticSettings' }
        @{ Canonical = 'Oracle.Database/cloudVmClusters/Microsoft.Insights/diagnosticSettings' }
    ) {
        param($Canonical)
        InModuleScope Avm.Authoring -Parameters @{ Canonical = $Canonical } {
            param($Canonical)
            $context = [pscustomobject]@{ Root = Join-Path $TestDrive 'renamed'; Ecosystem = 'bicep' }
            { Get-AvmMetadataModuleType -Context $context -Path $context.Root -Metadata @{ canonicalType = $Canonical } } |
                Should -Throw '*Cannot determine whether*'
        }
    }

    It 'recognizes a single-segment Terraform <ModuleType> identity without telemetry' -TestCases @(
        @{ Kind = 'ptn'; Canonical = 'alz'; ModuleType = 'pattern' }
        @{ Kind = 'utl'; Canonical = 'naming'; ModuleType = 'utility' }
    ) {
        param($Kind, $Canonical, $ModuleType)
        InModuleScope Avm.Authoring -Parameters @{ Kind = $Kind; Canonical = $Canonical; ModuleType = $ModuleType } {
            param($Kind, $Canonical, $ModuleType)
            $context = [pscustomobject]@{
                Root = Join-Path $TestDrive "terraform-azure-avm-$Kind-$Canonical"
                Ecosystem = 'terraform'
            }
            Get-AvmMetadataModuleType -Context $context -Path $context.Root -Metadata @{ canonicalType = $Canonical } |
                Should -Be $ModuleType
        }
    }

    It 'uses the Terraform root directory rather than a misleading ancestor name' {
        InModuleScope Avm.Authoring {
            $context = [pscustomobject]@{
                Root = Join-Path $TestDrive 'avm-res-parent' 'terraform-azurerm-avm-ptn-example-repo'
                Ecosystem = 'terraform'
            }
            Get-AvmMetadataModuleType -Context $context -Path (Join-Path $context.Root 'modules' 'child') `
                -Metadata @{ canonicalType = 'Microsoft.Storage/storageAccounts' } | Should -Be 'pattern'
        }
    }

    It 'resolves a renamed Terraform checkout from its local Git origin without fetching it' {
        InModuleScope Avm.Authoring {
            $context = [pscustomobject]@{ Root = Join-Path $TestDrive 'renamed'; Ecosystem = 'terraform' }
            Mock Test-Path { $true }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = 'git@github.com:Azure/terraform-azurerm-avm-utl-types-common.git'; StdErr = '' }
            }
            Get-AvmMetadataModuleType -Context $context -Path $context.Root -Metadata @{ canonicalType = 'types/common' } |
                Should -Be 'utility'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -join ' ') -eq 'config --get remote.origin.url' -and $WorkingDirectory -eq $context.Root
            }
        }
    }

    It 'uses the explicit context scope for a telemetry-free module outside its normal path' {
        InModuleScope Avm.Authoring {
            $context = [pscustomobject]@{ Root = $TestDrive; Ecosystem = 'bicep'; Scope = 'utl' }
            Get-AvmMetadataModuleType -Context $context -Path $context.Root -Metadata @{ canonicalType = 'types/common' } |
                Should -Be 'utility'
        }
    }
}
