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
}
