#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepDocs (stub — walker reverted pending new CLI design)' {
    It 'throws ArgumentException when the context is not a bicep ecosystem' {
        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmBicepDocs -Context ([pscustomobject]@{ Ecosystem = 'terraform'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name | Should -Be 'ArgumentException'
        $err.Message        | Should -Match "Invoke-AvmBicepDocs requires a bicep context"
        $err.Message        | Should -Match "Ecosystem='terraform'"
    }

    It 'throws AvmConfigurationException for a bicep context (engine deferred to new CLI command)' {
        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmBicepDocs -Context ([pscustomobject]@{ Ecosystem = 'bicep'; Root = $TestDrive })
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'redesigned as a separate CLI command'
        $err.Message        | Should -Match 'docs/avm-consolidation-plan\.md'
    }
}
