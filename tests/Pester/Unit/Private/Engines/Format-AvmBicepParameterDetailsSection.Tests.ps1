#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Format-AvmBicepParameterDetailsSection' {
    It 'returns an empty array when the ARM has no parameters' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $result.Count | Should -Be 0
    }

    It 'renders a minimal detail block for a required string parameter' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. The name of the resource.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $result[0] | Should -Be '### Parameter: `name`'
        $result[1] | Should -Be ''
        $result[2] | Should -Be 'The name of the resource.'
        $result[3] | Should -Be ''
        $result[4] | Should -Be '- Required: Yes'
        $result[5] | Should -Be '- Type: string'
        $result.Count | Should -Be 6
    }

    It 'emits Required = No and a Default line when defaultValue is present' {
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
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $joined = $result -join "`n"
        $joined | Should -Match '- Required: No'
        $joined | Should -Match '- Default: `eastus`'
    }

    It 'emits Allowed, MinValue, MaxValue bullets only when present' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                tier = [pscustomobject]@{
                    type          = 'int'
                    allowedValues = @(1, 2, 4)
                    minValue      = 1
                    maxValue      = 4
                    metadata      = [pscustomobject]@{ description = 'Required. Tier.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $joined = $result -join "`n"
        $joined | Should -Match '- Allowed: `\[ 1, 2, 4 \]`'
        $joined | Should -Match '- MinValue: 1'
        $joined | Should -Match '- MaxValue: 4'
    }

    It 'renders a single-line example as an inline backticked line' {
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
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        ($result -join "`n") | Should -Match '- Example: `my-name`'
    }

    It 'renders a multi-line example as a fenced bicep code block with two-space indentation' {
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
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $joined = $result -join "`n"
        $joined | Should -Match '- Example:'
        $joined | Should -Match '  ```bicep'
        $joined | Should -Match "  env: 'prod'"
        $joined | Should -Match "  owner: 'team'"
        $joined | Should -Match '  ```'
    }

    It 'orders blocks by Required, Conditional, Optional, Generated then alphabetically within' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                opt   = [pscustomobject]@{ type = 'string'; defaultValue = 'x'; metadata = [pscustomobject]@{ description = 'Optional. o.' } }
                cond  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Conditional. c.' } }
                zeta  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. z.' } }
                alpha = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. a.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $joined = $result -join "`n"
        $aIdx = $joined.IndexOf('### Parameter: `alpha`')
        $zIdx = $joined.IndexOf('### Parameter: `zeta`')
        $cIdx = $joined.IndexOf('### Parameter: `cond`')
        $oIdx = $joined.IndexOf('### Parameter: `opt`')
        $aIdx | Should -BeGreaterThan -1
        $zIdx | Should -BeGreaterThan $aIdx
        $cIdx | Should -BeGreaterThan $zIdx
        $oIdx | Should -BeGreaterThan $cIdx
    }

    It 'emits a heading + bullets even for object-typed parameters (no recursion when properties is absent)' {
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
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $joined = $result -join "`n"
        $joined | Should -Match '### Parameter: `tags`'
        $joined | Should -Match '- Type: object'
        $joined | Should -Not -Match '### Parameter: `tags\.'
    }

    It 'separates consecutive parameter blocks with a single blank line' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                a = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. a.' } }
                b = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. b.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $aIdx = [Array]::IndexOf($result, '### Parameter: `a`')
        $bIdx = [Array]::IndexOf($result, '### Parameter: `b`')
        $aIdx | Should -BeGreaterThan -1
        $bIdx | Should -BeGreaterThan $aIdx
        # The line immediately before the second parameter block must be a blank separator.
        $result[$bIdx - 1] | Should -Be ''
    }

    It 'emits a child block immediately after its parent for an inline object with one scalar child' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                tags = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Tags.' }
                    properties = [pscustomobject]@{
                        env = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Env value.' } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $parentIdx = [Array]::IndexOf($result, '### Parameter: `tags`')
        $childIdx  = [Array]::IndexOf($result, '### Parameter: `tags.env`')
        $parentIdx | Should -BeGreaterThan -1
        $childIdx  | Should -BeGreaterThan $parentIdx
        # Blank line separates parent from child.
        $result[$childIdx - 1] | Should -Be ''
        # Child block emits a full heading + body + bullets.
        $result[$childIdx + 1] | Should -Be ''
        $result[$childIdx + 2] | Should -Be 'Env value.'
        $result[$childIdx + 3] | Should -Be ''
        $result[$childIdx + 4] | Should -Be '- Required: Yes'
        $result[$childIdx + 5] | Should -Be '- Type: string'
    }

    It 'recurses two levels and emits the grandchild block after the child block in declaration order' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                outer = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Outer.' }
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
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $outerIdx  = [Array]::IndexOf($result, '### Parameter: `outer`')
        $middleIdx = [Array]::IndexOf($result, '### Parameter: `outer.middle`')
        $innerIdx  = [Array]::IndexOf($result, '### Parameter: `outer.middle.inner`')
        $outerIdx  | Should -BeGreaterThan -1
        $middleIdx | Should -BeGreaterThan $outerIdx
        $innerIdx  | Should -BeGreaterThan $middleIdx
    }

    It 'keeps each parent and its child glued together when multiple required parents are present' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                alpha = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Alpha.' }
                    properties = [pscustomobject]@{
                        aa = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'aa.' } }
                    }
                }
                beta = [pscustomobject]@{
                    type       = 'object'
                    metadata   = [pscustomobject]@{ description = 'Required. Beta.' }
                    properties = [pscustomobject]@{
                        bb = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'bb.' } }
                    }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParameterDetailsSection -Arm $A
        }
        $alphaIdx   = [Array]::IndexOf($result, '### Parameter: `alpha`')
        $alphaAaIdx = [Array]::IndexOf($result, '### Parameter: `alpha.aa`')
        $betaIdx    = [Array]::IndexOf($result, '### Parameter: `beta`')
        $betaBbIdx  = [Array]::IndexOf($result, '### Parameter: `beta.bb`')
        $alphaIdx   | Should -BeGreaterThan -1
        $alphaAaIdx | Should -BeGreaterThan $alphaIdx
        $betaIdx    | Should -BeGreaterThan $alphaAaIdx
        $betaBbIdx  | Should -BeGreaterThan $betaIdx
    }

    Context 'slice 4c: $ref-driven output' {
        It 'emits parent and child blocks when the parent is a $ref to an object UDT' {
            $arm = [pscustomobject]@{
                parameters  = [pscustomobject]@{
                    tags = [pscustomobject]@{
                        '$ref'   = '#/definitions/TagsType'
                        metadata = [pscustomobject]@{ description = 'Required. Tags.' }
                    }
                }
                definitions = [pscustomobject]@{
                    TagsType = [pscustomobject]@{
                        type       = 'object'
                        properties = [pscustomobject]@{
                            environment = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'env.' } }
                            owner       = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'owner.' } }
                        }
                    }
                }
            }
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Format-AvmBicepParameterDetailsSection -Arm $A
            }
            $parentIdx = [Array]::IndexOf($result, '### Parameter: `tags`')
            $envIdx    = [Array]::IndexOf($result, '### Parameter: `tags.environment`')
            $ownerIdx  = [Array]::IndexOf($result, '### Parameter: `tags.owner`')
            $parentIdx | Should -BeGreaterThan -1
            $envIdx    | Should -BeGreaterThan $parentIdx
            $ownerIdx  | Should -BeGreaterThan $envIdx
        }

        It 'truncates the children walk at the cycle leaf without emitting a second-level recurrence' {
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
                            label  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Label.' } }
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
                Format-AvmBicepParameterDetailsSection -Arm $A
            }
            $nodeIdx        = [Array]::IndexOf($result, '### Parameter: `node`')
            $labelIdx       = [Array]::IndexOf($result, '### Parameter: `node.label`')
            $parentIdx      = [Array]::IndexOf($result, '### Parameter: `node.parent`')
            $grandParentIdx = [Array]::IndexOf($result, '### Parameter: `node.parent.parent`')
            $nodeIdx        | Should -BeGreaterThan -1
            $labelIdx       | Should -BeGreaterThan $nodeIdx
            $parentIdx      | Should -BeGreaterThan $nodeIdx
            $grandParentIdx | Should -Be -1
        }
    }
}
