#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'AvmExceptions' {
    It 'AvmException is a System.Exception with a default code' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try { throw [AvmException]::new('boom') } catch { return $_.Exception }
        }
        $thrown -is [System.Exception] | Should -BeTrue
        $thrown.Message | Should -Be 'boom'
        $thrown.Code | Should -Be 'AVM0000'
    }

    It 'AvmException accepts a custom code' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try { throw [AvmException]::new('boom', 'AVM9999') } catch { return $_.Exception }
        }
        $thrown.Code | Should -Be 'AVM9999'
    }

    It 'AvmConfigurationException carries code AVM1001' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try { throw [AvmConfigurationException]::new('cfg') } catch { return $_.Exception }
        }
        $thrown.GetType().Name | Should -Be 'AvmConfigurationException'
        $thrown.Code | Should -Be 'AVM1001'
    }

    It 'AvmToolException carries default code AVM1010' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try { throw [AvmToolException]::new('tool') } catch { return $_.Exception }
        }
        $thrown.Code | Should -Be 'AVM1010'
    }

    It 'AvmToolException accepts a custom code' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try { throw [AvmToolException]::new('tool', 'AVM1099') } catch { return $_.Exception }
        }
        $thrown.Code | Should -Be 'AVM1099'
    }

    It 'AvmProcessException carries process detail properties' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try {
                throw [AvmProcessException]::new('exit 7', 'tf', @('plan', '-out=x'), 7, 'out', 'err')
            }
            catch { return $_.Exception }
        }
        $thrown.GetType().Name | Should -Be 'AvmProcessException'
        $thrown.Code | Should -Be 'AVM1020'
        $thrown.FileName | Should -Be 'tf'
        $thrown.ArgumentList | Should -Be @('plan', '-out=x')
        $thrown.ExitCode | Should -Be 7
        $thrown.StdOut | Should -Be 'out'
        $thrown.StdErr | Should -Be 'err'
    }

    It 'AvmContextException carries code AVM1030' {
        $thrown = InModuleScope 'Avm.Authoring' {
            try { throw [AvmContextException]::new('no context') } catch { return $_.Exception }
        }
        $thrown.GetType().Name | Should -Be 'AvmContextException'
        $thrown.Code | Should -Be 'AVM1030'
    }

    It 'preserves an inner exception' {
        $thrown = InModuleScope 'Avm.Authoring' {
            $inner = [System.IO.FileNotFoundException]::new('missing')
            try { throw [AvmConfigurationException]::new('outer', $inner) } catch { return $_.Exception }
        }
        $thrown.InnerException | Should -Not -BeNullOrEmpty
        $thrown.InnerException.GetType().FullName | Should -Be 'System.IO.FileNotFoundException'
    }
}
