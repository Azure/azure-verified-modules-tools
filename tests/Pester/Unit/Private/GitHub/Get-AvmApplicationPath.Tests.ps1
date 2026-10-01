#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmApplicationPath' {
    It 'returns the resolved application path' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Command { [pscustomobject]@{ Source = '/usr/bin/gh' } } -ParameterFilter { $Name -eq 'gh' }
            Get-AvmApplicationPath -Name gh | Should -BeExactly '/usr/bin/gh'
        }
    }

    It 'explains how to install a missing <Name>' -TestCases @(
        @{ Name = 'gh'; Hint = 'gh auth login' }
        @{ Name = 'git'; Hint = 'git-scm.com' }
    ) {
        param($Name, $Hint)
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Name = $Name } {
            param($Name)
            Mock Get-Command { $null }
            try { Get-AvmApplicationPath -Name $Name } catch { $_.Exception }
        }

        $probe.GetType().Name | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match "$Name was not found on PATH"
        $probe.Message | Should -Match ([regex]::Escape($Hint))
    }
}
