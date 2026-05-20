#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Format-AvmBicepOutputsSection' {
    It 'returns _None_ for an ARM template with no outputs property' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepOutputsSection -Arm $A
        }
        $result | Should -Be @('_None_')
    }

    It 'returns _None_ for an outputs object with zero keys' {
        $arm = [pscustomobject]@{ outputs = [pscustomobject]@{} }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepOutputsSection -Arm $A
        }
        $result | Should -Be @('_None_')
    }

    It 'emits a 2-column table when no output has a description' {
        $arm = [pscustomobject]@{
            outputs = [pscustomobject]@{
                resourceId = [pscustomobject]@{ type = 'string'; value = '...' }
                name       = [pscustomobject]@{ type = 'string'; value = '...' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepOutputsSection -Arm $A
        }
        $result[0]    | Should -Be '| Output | Type |'
        $result[1]    | Should -Be '| :-- | :-- |'
        $result.Count | Should -Be 4
        # en-US sort: 'name' before 'resourceId'
        $result[2]    | Should -Be '| `name` | string |'
        $result[3]    | Should -Be '| `resourceId` | string |'
    }

    It 'emits a 3-column table when any output has a description' {
        $arm = [pscustomobject]@{
            outputs = [pscustomobject]@{
                resourceId = [pscustomobject]@{
                    type     = 'string'
                    value    = '...'
                    metadata = [pscustomobject]@{ description = 'The resource ID.' }
                }
                name = [pscustomobject]@{ type = 'string'; value = '...' }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepOutputsSection -Arm $A
        }
        $result[0] | Should -Be '| Output | Type | Description |'
        $result[1] | Should -Be '| :-- | :-- | :-- |'
        # Order: en-US 'name' before 'resourceId'
        $result[2] | Should -Be '| `name` | string |  |'
        $result[3] | Should -Be '| `resourceId` | string | The resource ID. |'
    }

    It 'folds CRLF and LF newlines in descriptions to a p-token' {
        $arm = [pscustomobject]@{
            outputs = [pscustomobject]@{
                blob = [pscustomobject]@{
                    type     = 'string'
                    value    = '...'
                    metadata = [pscustomobject]@{ description = "line 1`nline 2`r`nline 3" }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepOutputsSection -Arm $A
        }
        $result[2] | Should -Be '| `blob` | string | line 1<p>line 2<p>line 3 |'
    }

    It 'treats a whitespace-only description as no description' {
        $arm = [pscustomobject]@{
            outputs = [pscustomobject]@{
                x = [pscustomobject]@{
                    type     = 'string'
                    value    = '...'
                    metadata = [pscustomobject]@{ description = '   ' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepOutputsSection -Arm $A
        }
        $result[0] | Should -Be '| Output | Type |'
    }
}
