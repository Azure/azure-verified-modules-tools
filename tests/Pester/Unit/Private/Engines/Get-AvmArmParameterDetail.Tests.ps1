#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmArmParameterDetail' {
    It 'returns an empty array when the ARM has no parameters' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result.Count | Should -Be 0
    }

    It 'returns minimal record for a required string parameter with no extras' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. The name.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $r = $result[0]
        $r.Name             | Should -Be 'name'
        $r.Type             | Should -Be 'string'
        $r.Category         | Should -Be 'Required'
        $r.IsRequired       | Should -BeTrue
        $r.HasDefault       | Should -BeFalse
        $r.HasAllowedValues | Should -BeFalse
        $r.HasMinValue      | Should -BeFalse
        $r.HasMaxValue      | Should -BeFalse
        $r.HasExample       | Should -BeFalse
    }

    It 'captures a primitive string defaultValue verbatim' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                location = [pscustomobject]@{
                    type         = 'string'
                    defaultValue = 'eastus'
                    metadata     = [pscustomobject]@{ description = 'Optional. The location.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasDefault | Should -BeTrue
        $result[0].Default    | Should -Be 'eastus'
    }

    It 'captures a boolean defaultValue as lowercased text' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                enable = [pscustomobject]@{
                    type         = 'bool'
                    defaultValue = $true
                    metadata     = [pscustomobject]@{ description = 'Optional. Enable.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].Default | Should -Be 'true'
    }

    It 'captures an integer defaultValue as numeric text' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                count = [pscustomobject]@{
                    type         = 'int'
                    defaultValue = 5
                    metadata     = [pscustomobject]@{ description = 'Optional. The count.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].Default | Should -Be '5'
    }

    It 'captures a complex defaultValue (array) as compressed JSON' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                regions = [pscustomobject]@{
                    type         = 'array'
                    defaultValue = @('eastus', 'westus')
                    metadata     = [pscustomobject]@{ description = 'Optional. Regions.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].Default | Should -Be '["eastus","westus"]'
    }

    It 'captures null as the literal text null' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                p = [pscustomobject]@{
                    type         = 'string'
                    defaultValue = $null
                    metadata     = [pscustomobject]@{ description = 'Optional. Nullable.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasDefault | Should -BeTrue
        $result[0].Default    | Should -Be 'null'
    }

    It 'renders allowedValues as a Bicep-style quoted array for strings' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                env = [pscustomobject]@{
                    type          = 'string'
                    allowedValues = @('dev', 'test', 'prod')
                    metadata      = [pscustomobject]@{ description = 'Required. Environment.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasAllowedValues | Should -BeTrue
        $result[0].AllowedValues    | Should -Be "[ 'dev', 'test', 'prod' ]"
    }

    It 'renders numeric allowedValues without quotes' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                tier = [pscustomobject]@{
                    type          = 'int'
                    allowedValues = @(1, 2, 4)
                    metadata      = [pscustomobject]@{ description = 'Required. Tier.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].AllowedValues | Should -Be '[ 1, 2, 4 ]'
    }

    It 'captures minValue and maxValue when present' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                n = [pscustomobject]@{
                    type     = 'int'
                    minValue = 1
                    maxValue = 10
                    metadata = [pscustomobject]@{ description = 'Required. Number.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasMinValue | Should -BeTrue
        $result[0].MinValue    | Should -Be 1
        $result[0].HasMaxValue | Should -BeTrue
        $result[0].MaxValue    | Should -Be 10
    }

    It 'captures a single-line metadata.example as one line with ExampleIsSingleLine = true' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{
                    type     = 'string'
                    metadata = [pscustomobject]@{ description = 'Required. Name.'; example = 'my-name' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasExample          | Should -BeTrue
        $result[0].ExampleIsSingleLine | Should -BeTrue
        $result[0].ExampleLines.Count  | Should -Be 1
        $result[0].ExampleLines[0]     | Should -Be 'my-name'
    }

    It 'captures a multi-line metadata.example preserving line order' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                tags = [pscustomobject]@{
                    type     = 'object'
                    metadata = [pscustomobject]@{ description = 'Optional. Tags.'; example = "env: 'prod'`r`nowner: 'team'" }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasExample          | Should -BeTrue
        $result[0].ExampleIsSingleLine | Should -BeFalse
        $result[0].ExampleLines.Count  | Should -Be 2
        $result[0].ExampleLines[0]     | Should -Be "env: 'prod'"
        $result[0].ExampleLines[1]     | Should -Be "owner: 'team'"
    }

    It 'ignores an empty or whitespace-only metadata.example' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                p = [pscustomobject]@{
                    type     = 'string'
                    metadata = [pscustomobject]@{ description = 'Required. P.'; example = "   `n  `n" }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].HasExample | Should -BeFalse
    }

    It 'propagates AvmConfigurationException when a parameter is missing its category prefix' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                bad = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'no prefix' } }
            }
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }
}
