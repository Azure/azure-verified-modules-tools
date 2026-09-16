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

Describe 'Metadata module identity' {
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
