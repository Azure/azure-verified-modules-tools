#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Test-AvmModuleVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'does not query the PowerShell Gallery before dispatching a command' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {}

            Invoke-Avm version | Out-Null

            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }
}
