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

    It 'emits a heading + bullets even for object-typed parameters (no recursion in slice 4a)' {
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
}
