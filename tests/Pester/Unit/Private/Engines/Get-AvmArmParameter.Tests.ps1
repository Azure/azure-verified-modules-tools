#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmArmParameter' {
    It 'returns an empty array when the ARM has no parameters property' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameter -Arm $A
        }
        $result.Count | Should -Be 0
    }

    It 'extracts Name, Type, Category, Description, IsRequired for a Required parameter (no defaultValue)' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                name = [pscustomobject]@{
                    type     = 'string'
                    metadata = [pscustomobject]@{ description = 'Required. The name of the resource.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameter -Arm $A
        }
        $result.Count          | Should -Be 1
        $result[0].Name        | Should -Be 'name'
        $result[0].Type        | Should -Be 'string'
        $result[0].Category    | Should -Be 'Required'
        $result[0].Description | Should -Be 'The name of the resource.'
        $result[0].IsRequired  | Should -BeTrue
    }

    It 'marks a parameter with defaultValue as not required' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                location = [pscustomobject]@{
                    type         = 'string'
                    defaultValue = 'eastus'
                    metadata     = [pscustomobject]@{ description = 'Optional. The location of the resource.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameter -Arm $A
        }
        $result[0].Category   | Should -Be 'Optional'
        $result[0].IsRequired | Should -BeFalse
    }

    It 'handles a non-standard category word (e.g. Generated) without losing it' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                deployTime = [pscustomobject]@{
                    type         = 'string'
                    defaultValue = '[utcNow()]'
                    metadata     = [pscustomobject]@{ description = 'Generated. The deployment time.' }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameter -Arm $A
        }
        $result[0].Category    | Should -Be 'Generated'
        $result[0].Description | Should -Be 'The deployment time.'
    }

    It 'folds newlines in descriptions: backtick-n-dash becomes list, CRLF and LF become paragraph breaks' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                p = [pscustomobject]@{
                    type     = 'string'
                    metadata = [pscustomobject]@{ description = "Required. line1`nline2`r`nline3`n- bullet1`n- bullet2" }
                }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameter -Arm $A
        }
        $result[0].Description | Should -Be 'line1<p>line2<p>line3<li>bullet1<li>bullet2'
    }

    It 'throws AvmConfigurationException when any parameter is missing a category prefix' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                ok  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. ok.' } }
                bad = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'no category here' } }
            }
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameter -Arm $A
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'bad'
        $err.Message        | Should -Not -Match '  - ok'
    }

    It 'throws AvmConfigurationException when a parameter has no metadata.description at all' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                bare = [pscustomobject]@{ type = 'string' }
            }
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
                param($A)
                Get-AvmArmParameter -Arm $A
            }
        }
        catch { $err = $_.Exception }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }

    It 'preserves parameter order (no implicit alphabetical sort \u2014 the formatter sorts)' {
        $arm = [pscustomobject]@{
            parameters = [pscustomobject]@{
                zeta  = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. z.' } }
                alpha = [pscustomobject]@{ type = 'string'; metadata = [pscustomobject]@{ description = 'Required. a.' } }
            }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Get-AvmArmParameter -Arm $A
        }
        $result[0].Name | Should -Be 'zeta'
        $result[1].Name | Should -Be 'alpha'
    }
}
