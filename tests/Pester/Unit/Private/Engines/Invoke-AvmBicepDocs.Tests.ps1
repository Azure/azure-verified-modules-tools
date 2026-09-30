#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepDocs' {
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

    It 'rejects alternative Bicep output paths before resolving a tool' {
        $err = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmBicepDocs -Context ([pscustomobject]@{ Ecosystem = 'bicep'; Root = $TestDrive }) `
                    -OutputFile 'elsewhere.md'
                $null
            }
            catch { $_.Exception }
        }
        $err.GetType().Name | Should -Be 'ArgumentException'
        $err.Message | Should -Match 'must be README.md'
    }
}
