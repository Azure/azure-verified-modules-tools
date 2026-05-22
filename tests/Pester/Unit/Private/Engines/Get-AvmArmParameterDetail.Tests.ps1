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

    It 'returns an empty Children array for a top-level scalar parameter' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. The name.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].PSObject.Properties['Children'] | Should -Not -BeNullOrEmpty
        @($result[0].Children).Count               | Should -Be 0
    }

    It 'returns an empty Children array for an object-typed parameter with no properties key' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                tags = [pscustomobject]@{
                    type     = 'object'
                    metadata = [pscustomobject]@{ description = 'Optional. Tags.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        @($result[0].Children).Count | Should -Be 0
    }

    It 'returns an empty Children array for an object-typed parameter with an empty properties bag' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                tags = [pscustomobject]@{
                    type       = 'object'
                    properties = [pscustomobject]@{}
                    metadata   = [pscustomobject]@{ description = 'Optional. Tags.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        @($result[0].Children).Count | Should -Be 0
    }

    It 'walks two scalar children of an inline object and yields dotted names with inherited category' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        first  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'First child.' } }
                        second = [pscustomobject]@{ type = 'int';    metadata = [pscustomobject]@{ description = 'Second child.' } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $parent = $result[0]
        $parent.Children.Count          | Should -Be 2
        $parent.Children[0].Name        | Should -Be 'outer.first'
        $parent.Children[0].Type        | Should -Be 'string'
        $parent.Children[0].Category    | Should -Be 'Required'
        $parent.Children[0].Description | Should -Be 'First child.'
        $parent.Children[0].IsRequired  | Should -BeTrue
        $parent.Children[1].Name        | Should -Be 'outer.second'
        $parent.Children[1].Type        | Should -Be 'int'
        $parent.Children[1].Category    | Should -Be 'Required'
    }

    It 'recurses two levels into nested objects with double-dotted names and inherited category' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Optional. Outer.' }
                    properties = [pscustomobject]@{
                        middle = [pscustomobject]@{
                            type       = 'object'
                            metadata   = [pscustomobject]@{ description = 'Middle child.' }
                            properties = [pscustomobject]@{
                                inner = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Inner.' } }
                            }
                        }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $parent = $result[0]
        $parent.Children.Count                      | Should -Be 1
        $parent.Children[0].Name                    | Should -Be 'outer.middle'
        $parent.Children[0].Category                | Should -Be 'Optional'
        $parent.Children[0].Children.Count          | Should -Be 1
        $parent.Children[0].Children[0].Name        | Should -Be 'outer.middle.inner'
        $parent.Children[0].Children[0].Category    | Should -Be 'Optional'
        $parent.Children[0].Children[0].Type        | Should -Be 'string'
        $parent.Children[0].Children[0].Description | Should -Be 'Inner.'
        $parent.Children[0].Children[0].IsRequired  | Should -BeTrue
    }

    It 'treats a nested property with nullable true and no defaultValue as not required' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        opt = [pscustomobject]@{ type = 'string'; nullable = $true; metadata = [pscustomobject]@{ description = 'Optional child.' } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].Children[0].IsRequired | Should -BeFalse
    }

    It 'treats a nested property with neither defaultValue nor nullable as required' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        must = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required child.' } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $result[0].Children[0].IsRequired | Should -BeTrue
    }

    It 'captures a nested property defaultValue and marks the child not required' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        location = [pscustomobject]@{
                            type         = 'string'
                            defaultValue = 'eastus'
                            metadata     = [pscustomobject]@{ description = 'Optional child.' }
                        }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $child = $result[0].Children[0]
        $child.IsRequired | Should -BeFalse
        $child.HasDefault | Should -BeTrue
        $child.Default    | Should -Be 'eastus'
    }

    It 'captures nested allowedValues, minValue and maxValue using the same extraction shape as top-level' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        tier = [pscustomobject]@{
                            type          = 'int'
                            allowedValues = @(1, 2, 4)
                            minValue      = 1
                            maxValue      = 4
                            metadata      = [pscustomobject]@{ description = 'Tier child.' }
                        }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $child = $result[0].Children[0]
        $child.HasAllowedValues | Should -BeTrue
        $child.AllowedValues    | Should -Be '[ 1, 2, 4 ]'
        $child.HasMinValue      | Should -BeTrue
        $child.MinValue         | Should -Be 1
        $child.HasMaxValue      | Should -BeTrue
        $child.MaxValue         | Should -Be 4
    }

    It 'captures a nested single-line metadata example with ExampleIsSingleLine set to true' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        name = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Name child.'; example = 'my-name' } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $child = $result[0].Children[0]
        $child.HasExample          | Should -BeTrue
        $child.ExampleIsSingleLine | Should -BeTrue
        $child.ExampleLines.Count  | Should -Be 1
        $child.ExampleLines[0]     | Should -Be 'my-name'
    }

    It 'captures a nested multi-line metadata example preserving line order' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        block = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Block child.'; example = "first`r`nsecond" } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $child = $result[0].Children[0]
        $child.HasExample          | Should -BeTrue
        $child.ExampleIsSingleLine | Should -BeFalse
        $child.ExampleLines.Count  | Should -Be 2
        $child.ExampleLines[0]     | Should -Be 'first'
        $child.ExampleLines[1]     | Should -Be 'second'
    }

    It 'emits an empty description and no exception for a nested property with no metadata' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                    properties = [pscustomobject]@{
                        naked = [pscustomobject]@{ type = 'string' }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameterDetail -Arm $A
        }
        $child = $result[0].Children[0]
        $child.Description | Should -Be ''
    }

    Context 'slice 4c: $ref / definitions resolution' {
        It 'resolves a top-level $ref to an object UDT and walks its properties' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        '$ref'   = '#/definitions/TagsType'
                        metadata = [pscustomobject]@{ description = 'Required. Tags applied to the resource.' }
                    }
                }
                definitions = [pscustomobject]@{
                    TagsType = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            environment = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'The environment tag.' }
                            }
                            owner       = [pscustomobject]@{
                                type     = 'string'
                                nullable = $true
                                metadata = [pscustomobject]@{ description = 'The owner tag.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Type           | Should -Be 'object'
            $result[0].Children.Count | Should -Be 2
            $result[0].Children[0].Name        | Should -Be 'tags.environment'
            $result[0].Children[0].Type        | Should -Be 'string'
            $result[0].Children[0].IsRequired  | Should -BeTrue
            $result[0].Children[0].Description | Should -Be 'The environment tag.'
            $result[0].Children[1].Name        | Should -Be 'tags.owner'
            $result[0].Children[1].IsRequired  | Should -BeFalse
        }

        It 'resolves a top-level $ref to a scalar UDT and surfaces allowed values' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    sku = [pscustomobject]@{
                        '$ref'   = '#/definitions/SkuType'
                        metadata = [pscustomobject]@{ description = 'Required. The SKU.' }
                    }
                }
                definitions = [pscustomobject]@{
                    SkuType = [pscustomobject]@{
                        type          = 'string'
                        allowedValues = @('Basic', 'Standard', 'Premium')
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Type             | Should -Be 'string'
            $result[0].HasAllowedValues | Should -BeTrue
            $result[0].AllowedValues    | Should -Match 'Basic'
            $result[0].AllowedValues    | Should -Match 'Premium'
            $result[0].Children.Count   | Should -Be 0
        }

        It 'lets a local metadata.description win over the definition description' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        '$ref'   = '#/definitions/TagsType'
                        metadata = [pscustomobject]@{ description = 'Required. The local description.' }
                    }
                }
                definitions = [pscustomobject]@{
                    TagsType = [pscustomobject]@{
                        type     = 'object'
                        metadata = [pscustomobject]@{ description = 'Definition description.' }
                    }
                }
            }
            $base = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameter -Arm $A
            }
            $base[0].Description | Should -Be 'The local description.'
        }

        It 'lets a local defaultValue overlay the definition default' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    sku = [pscustomobject]@{
                        '$ref'        = '#/definitions/SkuType'
                        defaultValue  = 'Standard'
                        metadata      = [pscustomobject]@{ description = 'Optional. The SKU.' }
                    }
                }
                definitions = [pscustomobject]@{
                    SkuType = [pscustomobject]@{
                        type         = 'string'
                        defaultValue = 'Basic'
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].HasDefault | Should -BeTrue
            $result[0].Default    | Should -Be 'Standard'
        }

        It 'lets local allowedValues, minValue, maxValue, and metadata.example overlay the definition' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    count = [pscustomobject]@{
                        '$ref'         = '#/definitions/CountType'
                        allowedValues  = @(10, 20, 30)
                        minValue       = 10
                        maxValue       = 30
                        metadata       = [pscustomobject]@{
                            description = 'Required. Counter.'
                            example     = '20'
                        }
                    }
                }
                definitions = [pscustomobject]@{
                    CountType = [pscustomobject]@{
                        type          = 'int'
                        allowedValues = @(1, 2, 3)
                        minValue      = 1
                        maxValue      = 3
                        metadata      = [pscustomobject]@{ example = '1' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].MinValue          | Should -Be 10
            $result[0].MaxValue          | Should -Be 30
            $result[0].AllowedValues     | Should -Match '10'
            $result[0].AllowedValues     | Should -Match '30'
            $result[0].HasExample        | Should -BeTrue
            $result[0].ExampleLines[0]   | Should -Be '20'
        }

        It 'falls back to the definition fields when the local raw carries only $ref and a description' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    sku = [pscustomobject]@{
                        '$ref'   = '#/definitions/SkuType'
                        metadata = [pscustomobject]@{ description = 'Required. The SKU.' }
                    }
                }
                definitions = [pscustomobject]@{
                    SkuType = [pscustomobject]@{
                        type          = 'string'
                        allowedValues = @('A', 'B')
                        metadata      = [pscustomobject]@{ example = 'A' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].HasAllowedValues | Should -BeTrue
            $result[0].HasExample       | Should -BeTrue
            $result[0].ExampleLines[0]  | Should -Be 'A'
        }

        It 'resolves a $ref on a nested property and uses the property key for the dotted name' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    outer = [pscustomobject]@{
                        type       = 'object'
                        metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                        properties = [pscustomobject]@{
                            inner = [pscustomobject]@{
                                '$ref'   = '#/definitions/InnerType'
                                metadata = [pscustomobject]@{ description = 'The inner.' }
                            }
                        }
                    }
                }
                definitions = [pscustomobject]@{
                    InnerType = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            leaf = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'The leaf.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $inner = $result[0].Children[0]
            $inner.Name             | Should -Be 'outer.inner'
            $inner.Type             | Should -Be 'object'
            $inner.Children.Count   | Should -Be 1
            $inner.Children[0].Name | Should -Be 'outer.inner.leaf'
        }

        It 'detects a self-referential UDT and stops recursion at the cycle leaf' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    node = [pscustomobject]@{
                        '$ref'   = '#/definitions/NodeType'
                        metadata = [pscustomobject]@{ description = 'Required. Tree root.' }
                    }
                }
                definitions = [pscustomobject]@{
                    NodeType = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            label  = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Label.' }
                            }
                            parent = [pscustomobject]@{
                                '$ref'   = '#/definitions/NodeType'
                                metadata = [pscustomobject]@{ description = 'Parent node.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $top = $result[0]
            $top.Children.Count | Should -Be 2
            $parent = $top.Children | Where-Object { $_.Name -eq 'node.parent' }
            $parent              | Should -Not -BeNullOrEmpty
            $parent.Type         | Should -Be 'object'
            $parent.Children.Count | Should -Be 0
        }

        It 'detects an indirect A->B->A cycle and stops the leaf branch' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    a = [pscustomobject]@{
                        '$ref'   = '#/definitions/A'
                        metadata = [pscustomobject]@{ description = 'Required. A.' }
                    }
                }
                definitions = [pscustomobject]@{
                    A = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            toB = [pscustomobject]@{
                                '$ref'   = '#/definitions/B'
                                metadata = [pscustomobject]@{ description = 'B.' }
                            }
                        }
                    }
                    B = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            backToA = [pscustomobject]@{
                                '$ref'   = '#/definitions/A'
                                metadata = [pscustomobject]@{ description = 'A again.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $top = $result[0]
            $top.Children.Count                 | Should -Be 1
            $top.Children[0].Children.Count     | Should -Be 1
            $top.Children[0].Children[0].Name              | Should -Be 'a.toB.backToA'
            $top.Children[0].Children[0].Children.Count    | Should -Be 0
        }

        It 'throws an AvmConfigurationException when $ref points at a missing definition' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        '$ref'   = '#/definitions/MissingType'
                        metadata = [pscustomobject]@{ description = 'Required. Tags.' }
                    }
                }
                definitions = [pscustomobject]@{}
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
            $err.Message        | Should -Match 'MissingType'
        }

        It 'throws an AvmConfigurationException for a malformed $ref' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        '$ref'   = '#/types/TagsType'
                        metadata = [pscustomobject]@{ description = 'Required. Tags.' }
                    }
                }
                definitions = [pscustomobject]@{
                    TagsType = [pscustomobject]@{ type = 'object' }
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
            $err.Message        | Should -Match 'Malformed'
        }

        It 'caps recursion at $script:AvmMaxRefDepth on a long linear chain' {
            $defs = [pscustomobject]@{}
            for ($i = 0; $i -lt 35; $i++) {
                $body = if ($i -lt 34) {
                    [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            next = [pscustomobject]@{
                                '$ref' = ('#/definitions/T{0}' -f ($i + 1))
                            }
                        }
                    }
                } else {
                    [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            leaf = [pscustomobject]@{ type = 'string' }
                        }
                    }
                }
                $defs.PSObject.Properties.Add(
                    [System.Management.Automation.PSNoteProperty]::new(('T{0}' -f $i), $body))
            }
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    root = [pscustomobject]@{
                        '$ref'   = '#/definitions/T0'
                        metadata = [pscustomobject]@{ description = 'Required. Root.' }
                    }
                }
                definitions = $defs
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $cursor = $result[0]
            $depthHit = 0
            while ($cursor.Children.Count -gt 0 -and $depthHit -lt 100) {
                $cursor = $cursor.Children[0]
                $depthHit++
            }
            $depthHit | Should -BeLessOrEqual 32
            $depthHit | Should -BeGreaterThan 0
        }

        It 'falls back to the definition description when the child $ref has no local metadata' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    outer = [pscustomobject]@{
                        type       = 'object'
                        metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
                        properties = [pscustomobject]@{
                            inner = [pscustomobject]@{
                                '$ref' = '#/definitions/InnerType'
                            }
                        }
                    }
                }
                definitions = [pscustomobject]@{
                    InnerType = [pscustomobject]@{
                        type     = 'string'
                        metadata = [pscustomobject]@{ description = 'The inner description from the definition.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children[0].Description | Should -Be 'The inner description from the definition.'
        }
    }

    Context 'slice 4d: array items recursion' {
        It 'emits a single parent[*] child for an array of scalars' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{ type = 'string' }
                        metadata = [pscustomobject]@{ description = 'Required. Tags applied to the resource.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Type           | Should -Be 'array'
            $result[0].Children.Count | Should -Be 1
            $child = $result[0].Children[0]
            $child.Name             | Should -Be 'tags[*]'
            $child.Type             | Should -Be 'string'
            $child.IsRequired       | Should -BeTrue
            $child.Category         | Should -Be 'Required'
            $child.Children.Count   | Should -Be 0
        }

        It 'emits no children when an array parameter has no items shape' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        type     = 'array'
                        metadata = [pscustomobject]@{ description = 'Required. Tags.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Type           | Should -Be 'array'
            $result[0].Children.Count | Should -Be 0
        }

        It 'recurses into items.properties for an array of inline objects' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    rules = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{
                            type       = 'object'
                            properties = [pscustomobject]@{
                                first  = [pscustomobject]@{
                                    type     = 'string'
                                    metadata = [pscustomobject]@{ description = 'First field.' }
                                }
                                second = [pscustomobject]@{
                                    type     = 'int'
                                    metadata = [pscustomobject]@{ description = 'Second field.' }
                                }
                            }
                        }
                        metadata = [pscustomobject]@{ description = 'Required. Rules.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $itemRecord = $result[0].Children[0]
            $itemRecord.Name             | Should -Be 'rules[*]'
            $itemRecord.Type             | Should -Be 'object'
            $itemRecord.Children.Count   | Should -Be 2
            $itemRecord.Children[0].Name | Should -Be 'rules[*].first'
            $itemRecord.Children[1].Name | Should -Be 'rules[*].second'
            $itemRecord.Children[0].Type | Should -Be 'string'
            $itemRecord.Children[1].Type | Should -Be 'int'
        }

        It 'resolves items.$ref to an object UDT and walks the resolved properties' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    rules = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{ '$ref' = '#/definitions/RuleType' }
                        metadata = [pscustomobject]@{ description = 'Required. Rules.' }
                    }
                }
                definitions = [pscustomobject]@{
                    RuleType = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            id   = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Rule id.' }
                            }
                            kind = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Rule kind.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $itemRecord = $result[0].Children[0]
            $itemRecord.Name             | Should -Be 'rules[*]'
            $itemRecord.Type             | Should -Be 'object'
            $itemRecord.Children.Count   | Should -Be 2
            $itemRecord.Children[0].Name | Should -Be 'rules[*].id'
            $itemRecord.Children[1].Name | Should -Be 'rules[*].kind'
        }

        It 'detects a cycle when an items.$ref re-enters the same definition' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    tree = [pscustomobject]@{
                        '$ref'   = '#/definitions/NodeType'
                        metadata = [pscustomobject]@{ description = 'Required. Forest.' }
                    }
                }
                definitions = [pscustomobject]@{
                    NodeType = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            children = [pscustomobject]@{
                                type     = 'array'
                                items    = [pscustomobject]@{ '$ref' = '#/definitions/NodeType' }
                                metadata = [pscustomobject]@{ description = 'Child nodes.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $top = $result[0]
            $top.Type             | Should -Be 'object'
            $childrenProp = $top.Children | Where-Object { $_.Name -eq 'tree.children' }
            $childrenProp         | Should -Not -BeNullOrEmpty
            $childrenProp.Type    | Should -Be 'array'
            $childrenProp.Children.Count | Should -Be 1
            $itemRecord = $childrenProp.Children[0]
            $itemRecord.Name      | Should -Be 'tree.children[*]'
            $itemRecord.Type      | Should -Be 'object'
            $itemRecord.Children.Count | Should -Be 0
        }

        It 'surfaces items.allowedValues on the synthetic parent[*] child' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    levels = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{
                            type          = 'string'
                            allowedValues = @('Low', 'Medium', 'High')
                        }
                        metadata = [pscustomobject]@{ description = 'Required. Levels.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $child = $result[0].Children[0]
            $child.Name             | Should -Be 'levels[*]'
            $child.Type             | Should -Be 'string'
            $child.HasAllowedValues | Should -BeTrue
            $child.AllowedValues    | Should -Match 'Low'
            $child.AllowedValues    | Should -Match 'High'
        }

        It 'reads items.metadata.description onto the synthetic parent[*] child' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{
                            type     = 'string'
                            metadata = [pscustomobject]@{ description = 'A single tag string.' }
                        }
                        metadata = [pscustomobject]@{ description = 'Required. Tags.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children[0].Description | Should -Be 'A single tag string.'
        }

        It 'walks an array property nested inside an object parameter' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    config = [pscustomobject]@{
                        type       = 'object'
                        metadata   = [pscustomobject]@{ description = 'Required. Config.' }
                        properties = [pscustomobject]@{
                            list = [pscustomobject]@{
                                type     = 'array'
                                items    = [pscustomobject]@{ type = 'string' }
                                metadata = [pscustomobject]@{ description = 'A list of strings.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $listChild = $result[0].Children[0]
            $listChild.Name             | Should -Be 'config.list'
            $listChild.Type             | Should -Be 'array'
            $listChild.Children.Count   | Should -Be 1
            $listChild.Children[0].Name | Should -Be 'config.list[*]'
            $listChild.Children[0].Type | Should -Be 'string'
        }

        It 'composes the synthetic suffix when items is itself an array' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    grid = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{
                            type  = 'array'
                            items = [pscustomobject]@{ type = 'string' }
                        }
                        metadata = [pscustomobject]@{ description = 'Required. Grid.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $outerItem = $result[0].Children[0]
            $outerItem.Name             | Should -Be 'grid[*]'
            $outerItem.Type             | Should -Be 'array'
            $outerItem.Children.Count   | Should -Be 1
            $outerItem.Children[0].Name | Should -Be 'grid[*][*]'
            $outerItem.Children[0].Type | Should -Be 'string'
        }
    }

    Context 'slice 4e: discriminator dispatch' {
        It 'dispatches a top-level $ref union into one synthetic child per mapping entry' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/ComputeUnion'
                        metadata = [pscustomobject]@{ description = 'Required. The compute spec.' }
                    }
                }
                definitions = [pscustomobject]@{
                    ComputeUnion   = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                WindowsVM = [pscustomobject]@{ '$ref' = '#/definitions/WindowsVmSpec' }
                                LinuxVM   = [pscustomobject]@{ '$ref' = '#/definitions/LinuxVmSpec' }
                            }
                        }
                    }
                    WindowsVmSpec  = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            kind     = [pscustomobject]@{
                                type          = 'string'
                                allowedValues = @('WindowsVM')
                                metadata      = [pscustomobject]@{ description = 'The kind discriminator.' }
                            }
                            edition  = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Windows edition.' }
                            }
                        }
                    }
                    LinuxVmSpec    = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            kind   = [pscustomobject]@{
                                type          = 'string'
                                allowedValues = @('LinuxVM')
                                metadata      = [pscustomobject]@{ description = 'The kind discriminator.' }
                            }
                            distro = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Linux distro.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Type             | Should -Be 'object'
            $result[0].Children.Count   | Should -Be 2
            $result[0].Children[0].Name        | Should -Be 'computeSpec[WindowsVM]'
            $result[0].Children[0].IsRequired  | Should -BeTrue
            $result[0].Children[0].Children.Count | Should -Be 2
            $result[0].Children[1].Name        | Should -Be 'computeSpec[LinuxVM]'
            $result[0].Children[1].IsRequired  | Should -BeTrue
            $result[0].Children[1].Children.Count | Should -Be 2
        }

        It 'returns zero children for an empty mapping but emits the parent record' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/EmptyUnion'
                        metadata = [pscustomobject]@{ description = 'Required. Empty union.' }
                    }
                }
                definitions = [pscustomobject]@{
                    EmptyUnion = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{}
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Type           | Should -Be 'object'
            $result[0].Children.Count | Should -Be 0
        }

        It 'recurses into an inline variant target without going through definitions' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                Inline = [pscustomobject]@{
                                    type       = 'object'
                                    properties = [pscustomobject]@{
                                        kind  = [pscustomobject]@{
                                            type          = 'string'
                                            allowedValues = @('Inline')
                                            metadata      = [pscustomobject]@{ description = 'The kind discriminator.' }
                                        }
                                        field = [pscustomobject]@{
                                            type     = 'string'
                                            metadata = [pscustomobject]@{ description = 'Inline field.' }
                                        }
                                    }
                                }
                            }
                        }
                        metadata      = [pscustomobject]@{ description = 'Required. Inline union.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children.Count             | Should -Be 1
            $result[0].Children[0].Name           | Should -Be 'computeSpec[Inline]'
            $result[0].Children[0].Type           | Should -Be 'object'
            $result[0].Children[0].Children.Count | Should -Be 2
            $result[0].Children[0].Children[1].Name | Should -Be 'computeSpec[Inline].field'
        }

        It 'throws an AvmConfigurationException when discriminator.propertyName is missing' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/BadUnion'
                        metadata = [pscustomobject]@{ description = 'Required. Bad union.' }
                    }
                }
                definitions = [pscustomobject]@{
                    BadUnion = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            mapping = [pscustomobject]@{
                                WindowsVM = [pscustomobject]@{ '$ref' = '#/definitions/WindowsVmSpec' }
                            }
                        }
                    }
                    WindowsVmSpec = [pscustomobject]@{ type = 'object' }
                }
            }
            $err = $null
            try {
                InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                    param($A)
                    Get-AvmArmParameterDetail -Arm $A
                }
            } catch { $err = $_.Exception }
            $err                | Should -Not -BeNullOrEmpty
            $err.GetType().Name | Should -Be 'AvmConfigurationException'
            $err.Message        | Should -Match 'computeSpec'
            $err.Message        | Should -Match 'propertyName'
        }

        It 'throws an AvmConfigurationException when a discriminator mapping value is null' {
            $mapping = [pscustomobject]@{}
            Add-Member -InputObject $mapping -MemberType NoteProperty -Name 'WindowsVM' -Value $null
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/NullVariantUnion'
                        metadata = [pscustomobject]@{ description = 'Required. Null variant.' }
                    }
                }
                definitions = [pscustomobject]@{
                    NullVariantUnion = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = $mapping
                        }
                    }
                }
            }
            $err = $null
            try {
                InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                    param($A)
                    Get-AvmArmParameterDetail -Arm $A
                }
            } catch { $err = $_.Exception }
            $err                | Should -Not -BeNullOrEmpty
            $err.GetType().Name | Should -Be 'AvmConfigurationException'
            $err.Message        | Should -Match 'computeSpec'
            $err.Message        | Should -Match 'WindowsVM'
        }

        It 'composes dotted naming when a discriminator is reached through an object property' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    top = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            inner = [pscustomobject]@{
                                '$ref'   = '#/definitions/Inner'
                                metadata = [pscustomobject]@{ description = 'The inner union.' }
                            }
                        }
                        metadata   = [pscustomobject]@{ description = 'Required. The top object.' }
                    }
                }
                definitions = [pscustomobject]@{
                    Inner       = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                WindowsVM = [pscustomobject]@{ '$ref' = '#/definitions/Win' }
                            }
                        }
                    }
                    Win         = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            edition = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Edition.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children.Count                       | Should -Be 1
            $result[0].Children[0].Name                     | Should -Be 'top.inner'
            $result[0].Children[0].Children.Count           | Should -Be 1
            $result[0].Children[0].Children[0].Name         | Should -Be 'top.inner[WindowsVM]'
            $result[0].Children[0].Children[0].Children[0].Name | Should -Be 'top.inner[WindowsVM].edition'
        }

        It 'composes array recursion with discriminator dispatch into parent[*][variantKey]' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    specs = [pscustomobject]@{
                        type     = 'array'
                        items    = [pscustomobject]@{ '$ref' = '#/definitions/ComputeUnion' }
                        metadata = [pscustomobject]@{ description = 'Required. The specs.' }
                    }
                }
                definitions = [pscustomobject]@{
                    ComputeUnion = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                WindowsVM = [pscustomobject]@{ '$ref' = '#/definitions/Win' }
                            }
                        }
                    }
                    Win          = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            edition = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Edition.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children.Count                       | Should -Be 1
            $result[0].Children[0].Name                     | Should -Be 'specs[*]'
            $result[0].Children[0].Children.Count           | Should -Be 1
            $result[0].Children[0].Children[0].Name         | Should -Be 'specs[*][WindowsVM]'
            $result[0].Children[0].Children[0].Children[0].Name | Should -Be 'specs[*][WindowsVM].edition'
        }

        It 'recurses into a nested discriminator inside a variant target' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/Outer'
                        metadata = [pscustomobject]@{ description = 'Required. Nested unions.' }
                    }
                }
                definitions = [pscustomobject]@{
                    Outer = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                Group = [pscustomobject]@{ '$ref' = '#/definitions/Inner' }
                            }
                        }
                    }
                    Inner = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'flavour'
                            mapping      = [pscustomobject]@{
                                Hot = [pscustomobject]@{ '$ref' = '#/definitions/Leaf' }
                            }
                        }
                    }
                    Leaf  = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            label = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Label.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children.Count                       | Should -Be 1
            $result[0].Children[0].Name                     | Should -Be 'computeSpec[Group]'
            $result[0].Children[0].Children.Count           | Should -Be 1
            $result[0].Children[0].Children[0].Name         | Should -Be 'computeSpec[Group][Hot]'
            $result[0].Children[0].Children[0].Children[0].Name | Should -Be 'computeSpec[Group][Hot].label'
        }

        It 'ignores the parent properties bag when discriminator is also present' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/HybridUnion'
                        metadata = [pscustomobject]@{ description = 'Required. Hybrid.' }
                    }
                }
                definitions = [pscustomobject]@{
                    HybridUnion = [pscustomobject]@{
                        type          = 'object'
                        properties    = [pscustomobject]@{
                            sharedField = [pscustomobject]@{ type = 'string' }
                        }
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                WindowsVM = [pscustomobject]@{ '$ref' = '#/definitions/Win' }
                            }
                        }
                    }
                    Win         = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            edition = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Edition.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children.Count       | Should -Be 1
            $result[0].Children[0].Name     | Should -Be 'computeSpec[WindowsVM]'
            ($result[0].Children | Where-Object { $_.Name -eq 'computeSpec.sharedField' }) | Should -BeNullOrEmpty
        }

        It 'surfaces the discriminator key as a constrained string child via the variant properties' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    computeSpec = [pscustomobject]@{
                        '$ref'   = '#/definitions/ComputeUnion'
                        metadata = [pscustomobject]@{ description = 'Required. Compute.' }
                    }
                }
                definitions = [pscustomobject]@{
                    ComputeUnion  = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                WindowsVM = [pscustomobject]@{ '$ref' = '#/definitions/WindowsVmSpec' }
                            }
                        }
                    }
                    WindowsVmSpec = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            kind = [pscustomobject]@{
                                type          = 'string'
                                allowedValues = @('WindowsVM')
                                metadata      = [pscustomobject]@{ description = 'The kind discriminator.' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $variant = $result[0].Children[0]
            $variant.Name                       | Should -Be 'computeSpec[WindowsVM]'
            $variant.Children.Count             | Should -Be 1
            $variant.Children[0].Name           | Should -Be 'computeSpec[WindowsVM].kind'
            $variant.Children[0].Type           | Should -Be 'string'
            $variant.Children[0].HasAllowedValues | Should -BeTrue
            $variant.Children[0].AllowedValues  | Should -Match 'WindowsVM'
        }

        It 'truncates a cycle reached through a discriminator variant ref' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    node = [pscustomobject]@{
                        '$ref'   = '#/definitions/Union'
                        metadata = [pscustomobject]@{ description = 'Required. Recursive union.' }
                    }
                }
                definitions = [pscustomobject]@{
                    Union = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                recurse = [pscustomobject]@{ '$ref' = '#/definitions/Union' }
                            }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $result[0].Children.Count       | Should -Be 1
            $result[0].Children[0].Name     | Should -Be 'node[recurse]'
            $result[0].Children[0].Children.Count | Should -Be 0
        }
    }

    Context 'slice 4f: special-cases (UDT-only constraints, sentinel values, secureObject)' {
        It 'passes a top-level securestring type through verbatim without defaultValue' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    adminPassword = [pscustomobject]@{
                        type     = 'securestring'
                        metadata = [pscustomobject]@{ description = 'Required. The administrator password.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Type        | Should -Be 'securestring'
            $r.IsRequired  | Should -BeTrue
            $r.HasDefault  | Should -BeFalse
            $r.Children.Count | Should -Be 0
        }

        It 'preserves a securestring defaultValue verbatim (matches app/managed-environment)' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    adminPassword = [pscustomobject]@{
                        type         = 'securestring'
                        defaultValue = ''
                        metadata     = [pscustomobject]@{ description = 'Optional. The administrator password.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Type        | Should -Be 'securestring'
            $r.IsRequired  | Should -BeFalse
            $r.HasDefault  | Should -BeTrue
            $r.Default     | Should -Be ''
        }

        It 'does not recurse into properties on a top-level secureobject parameter (matches walker scope: only literal type=object recurses)' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    secrets = [pscustomobject]@{
                        type       = 'secureobject'
                        properties = [pscustomobject]@{
                            foo = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'The foo secret.' }
                            }
                            bar = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'The bar secret.' }
                            }
                        }
                        metadata   = [pscustomobject]@{ description = 'Required. Secret bag.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Type           | Should -Be 'secureobject'
            $r.Children.Count | Should -Be 0
        }

        It 'preserves a nested securestring under an object parent via slice-4b dotted name' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    config = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            secret = [pscustomobject]@{
                                type     = 'securestring'
                                metadata = [pscustomobject]@{ description = 'The nested secret.' }
                            }
                        }
                        metadata   = [pscustomobject]@{ description = 'Required. Config blob.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Children.Count | Should -Be 1
            $r.Children[0].Name | Should -Be 'config.secret'
            $r.Children[0].Type | Should -Be 'securestring'
        }

        It 'ignores additionalProperties: false on an object and walks declared properties only' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    closed = [pscustomobject]@{
                        type                 = 'object'
                        additionalProperties = $false
                        properties           = [pscustomobject]@{
                            only = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'The only allowed key.' }
                            }
                        }
                        metadata             = [pscustomobject]@{ description = 'Required. Closed object.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Children.Count   | Should -Be 1
            $r.Children[0].Name | Should -Be 'closed.only'
        }

        It 'ignores additionalProperties: { type } open-map schema and emits no synthetic child' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    bag = [pscustomobject]@{
                        type                 = 'object'
                        additionalProperties = [pscustomobject]@{ type = 'string' }
                        properties           = [pscustomobject]@{
                            known = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'The known key.' }
                            }
                        }
                        metadata             = [pscustomobject]@{ description = 'Required. Open-map object.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Children.Count   | Should -Be 1
            $r.Children[0].Name | Should -Be 'bag.known'
        }

        It 'does not surface minLength or maxLength on a string parameter (matches legacy contract)' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    name = [pscustomobject]@{
                        type      = 'string'
                        minLength = 3
                        maxLength = 24
                        metadata  = [pscustomobject]@{ description = 'Required. The constrained name.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Type | Should -Be 'string'
            $r.PSObject.Properties['MinLength'] | Should -BeNullOrEmpty
            $r.PSObject.Properties['MaxLength'] | Should -BeNullOrEmpty
            $r.PSObject.Properties['HasMinLength'] | Should -BeNullOrEmpty
            $r.PSObject.Properties['HasMaxLength'] | Should -BeNullOrEmpty
        }

        It 'does not surface a regex pattern on a string parameter (matches legacy contract)' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    sku = [pscustomobject]@{
                        type     = 'string'
                        pattern  = '^[A-Z][a-z]+$'
                        metadata = [pscustomobject]@{ description = 'Required. The sku name.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Type | Should -Be 'string'
            $r.PSObject.Properties['Pattern'] | Should -BeNullOrEmpty
            $r.PSObject.Properties['HasPattern'] | Should -BeNullOrEmpty
        }

        It 'reports IsRequired = Yes for a top-level nullable: true parameter with no defaultValue (matches legacy)' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    optionalTag = [pscustomobject]@{
                        type     = 'string'
                        nullable = $true
                        metadata = [pscustomobject]@{ description = 'Required. Optionally null tag.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.IsRequired | Should -BeTrue
            $r.HasDefault | Should -BeFalse
        }

        It 'resolves hybrid properties + discriminator with discriminator wins (re-locks slice 4e decision)' {
            $arm = [pscustomobject]@{
                parameters = [pscustomobject]@{
                    spec = [pscustomobject]@{
                        type          = 'object'
                        discriminator = [pscustomobject]@{
                            propertyName = 'kind'
                            mapping      = [pscustomobject]@{
                                KindA = [pscustomobject]@{
                                    type       = 'object'
                                    properties = [pscustomobject]@{
                                        kind  = [pscustomobject]@{
                                            type          = 'string'
                                            allowedValues = @('KindA')
                                            metadata      = [pscustomobject]@{ description = 'The kind.' }
                                        }
                                        valueA = [pscustomobject]@{
                                            type     = 'string'
                                            metadata = [pscustomobject]@{ description = 'A value.' }
                                        }
                                    }
                                }
                                KindB = [pscustomobject]@{
                                    type       = 'object'
                                    properties = [pscustomobject]@{
                                        kind  = [pscustomobject]@{
                                            type          = 'string'
                                            allowedValues = @('KindB')
                                            metadata      = [pscustomobject]@{ description = 'The kind.' }
                                        }
                                        valueB = [pscustomobject]@{
                                            type     = 'string'
                                            metadata = [pscustomobject]@{ description = 'B value.' }
                                        }
                                    }
                                }
                            }
                        }
                        properties    = [pscustomobject]@{
                            ignoredShared = [pscustomobject]@{
                                type     = 'string'
                                metadata = [pscustomobject]@{ description = 'Should not appear.' }
                            }
                        }
                        metadata      = [pscustomobject]@{ description = 'Required. Hybrid object.' }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameterDetail -Arm $A
            }
            $r = $result[0]
            $r.Children.Count   | Should -Be 2
            $childNames = @($r.Children | ForEach-Object { $_.Name })
            $childNames | Should -Contain 'spec[KindA]'
            $childNames | Should -Contain 'spec[KindB]'
            $childNames | Should -Not -Contain 'spec.ignoredShared'
        }
    }
}
