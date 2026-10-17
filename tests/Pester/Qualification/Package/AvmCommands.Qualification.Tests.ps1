#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: avm command routes' -Tag Qualification {
BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:moduleManifest -Force
    }

AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

It 'finds the live PowerShell Gallery package as a module version' -Skip:(
        (Test-Path Env:\AVM_OFFLINE) -and $env:AVM_OFFLINE -eq '1') {
        $latestVersion = InModuleScope 'Avm.Authoring' {
            $script:AvmLatestModuleVersion = $null
            $script:AvmModuleVersionCheckCompleted = $false
            Get-AvmLatestModuleVersion
        }

        $latestVersion | Should -BeOfType [version]
        $latestVersion | Should -BeGreaterOrEqual (Get-Module Avm.Authoring).Version
    }
}
