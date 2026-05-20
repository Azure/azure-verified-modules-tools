#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Format-AvmBicepParametersSection' {
    It 'returns _None_ when the ARM has no parameters' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $result | Should -Be @('_None_')
    }

    It 'renders a single Required subsection with a 3-column table' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. The name of the resource.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $result[0] | Should -Be '**Required parameters**'
        $result[1] | Should -Be ''
        $result[2] | Should -Be '| Parameter | Type | Description |'
        $result[3] | Should -Be '| :-- | :-- | :-- |'
        $result[4] | Should -Be '| [`name`](#parameter-name) | string | The name of the resource. |'
        $result.Count | Should -Be 5
    }

    It 'emits subsections in Required, Conditional, Optional, Generated order' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                opt  = [pscustomobject]@{ type = 'string'; defaultValue = 'x'; metadata = [pscustomobject]@{ description = 'Optional. opt.' } }
                gen  = [pscustomobject]@{ type = 'string'; defaultValue = 'x'; metadata = [pscustomobject]@{ description = 'Generated. gen.' } }
                req  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. req.' } }
                cond = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Conditional. cond.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $joined = $result -join "`n"
        $reqIdx  = $joined.IndexOf('**Required parameters**')
        $condIdx = $joined.IndexOf('**Conditional parameters**')
        $optIdx  = $joined.IndexOf('**Optional parameters**')
        $genIdx  = $joined.IndexOf('**Generated parameters**')
        $reqIdx  | Should -BeGreaterThan -1
        $condIdx | Should -BeGreaterThan $reqIdx
        $optIdx  | Should -BeGreaterThan $condIdx
        $genIdx  | Should -BeGreaterThan $optIdx
    }

    It 'omits subsections for categories with no parameters' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. n.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $joined = $result -join "`n"
        $joined | Should -Match '\*\*Required parameters\*\*'
        $joined | Should -Not -Match '\*\*Conditional parameters\*\*'
        $joined | Should -Not -Match '\*\*Optional parameters\*\*'
        $joined | Should -Not -Match '\*\*Generated parameters\*\*'
    }

    It 'sorts rows within a category by Name with en-US culture' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                zeta  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. z.' } }
                alpha = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. a.' } }
                mid   = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. m.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $result[4] | Should -Match '`alpha`'
        $result[5] | Should -Match '`mid`'
        $result[6] | Should -Match '`zeta`'
    }

    It 'lowercases the anchor target but preserves the parameter name casing in the link text' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                enableTelemetry = [pscustomobject]@{ type = 'bool'; defaultValue = $true; metadata = [pscustomobject]@{ description = 'Optional. Enable telemetry.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $result[4] | Should -Be '| [`enableTelemetry`](#parameter-enabletelemetry) | bool | Enable telemetry. |'
    }

    It 'appends unknown categories after the known ones in first-seen order' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                weird  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Experimental. wx.' } }
                normal = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. n.' } }
                other  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Legacy. lx.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepParametersSection -Arm $A
        }
        $joined = $result -join "`n"
        $reqIdx  = $joined.IndexOf('**Required parameters**')
        $expIdx  = $joined.IndexOf('**Experimental parameters**')
        $legIdx  = $joined.IndexOf('**Legacy parameters**')
        $reqIdx  | Should -BeGreaterThan -1
        $expIdx  | Should -BeGreaterThan $reqIdx
        $legIdx  | Should -BeGreaterThan $expIdx
    }

    It 'propagates AvmConfigurationException from the walker when a parameter has no category prefix' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                bad = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'no prefix here' } }
            }
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Format-AvmBicepParametersSection -Arm $A
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }
}
