#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepCompiledJsonDrift' {
    It 'classifies an absent artifact as missing' {
        InModuleScope 'Avm.Authoring' {
            Get-AvmBicepCompiledJsonDrift -CompiledJson '{}' -CurrentBytes $null |
                Should -Be 'missing'
        }
    }

    It 'accepts only byte-identical output' {
        InModuleScope 'Avm.Authoring' {
            $compiled = "{}`n"
            $current = [System.Text.UTF8Encoding]::new($false).GetBytes($compiled)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $current |
                Should -BeNullOrEmpty
        }
    }

    It 'detects newline and BOM drift even when the JSON values are identical' {
        InModuleScope 'Avm.Authoring' {
            $compiled = "{}`n"
            $newlineDrift = [System.Text.UTF8Encoding]::new($false).GetBytes("{}`r`n")
            $bomDrift = [System.Text.UTF8Encoding]::new($true).GetPreamble() +
                [System.Text.UTF8Encoding]::new($false).GetBytes($compiled)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $newlineDrift |
                Should -Be 'stale'
            Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $bomDrift |
                Should -Be 'stale'
        }
    }
}
