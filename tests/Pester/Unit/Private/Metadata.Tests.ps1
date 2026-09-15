#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Strict metadata JSON' {
    It 'preserves a JSON object and arrays without evaluating values' {
        InModuleScope Avm.Authoring {
            $data = ConvertFrom-AvmMetadataJson -Json '{"owners":{"individuals":[{"githubHandle":"azure-owner"}]},"comments":"$(throw 1)"}'
            $data.owners.individuals.Count | Should -Be 1
            $data.comments | Should -BeExactly '$(throw 1)'
        }
    }

    It 'preserves ISO-looking JSON strings and empty arrays without date or null coercion' {
        InModuleScope Avm.Authoring {
            $data = ConvertFrom-AvmMetadataJson -Json '{"moduleDescription":"2024-07-01T00:30:00Z","nested":{"items":[]},"values":[null,true,1,"2024-07-01T00:30:00Z"]}'
            $data.moduleDescription | Should -BeOfType ([string])
            $data.moduleDescription | Should -BeExactly '2024-07-01T00:30:00Z'
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
