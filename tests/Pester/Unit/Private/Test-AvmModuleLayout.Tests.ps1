#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmModuleLayout' {
    It 'returns the manifest for the real module folder' {
        $manifest = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:moduleRoot } {
            param($R)
            Test-AvmModuleLayout -ModuleRoot $R
        }
        $manifest | Should -Not -BeNullOrEmpty
        $manifest.Name | Should -Be 'Avm.Authoring'
        $manifest.PowerShellVersion | Should -BeGreaterOrEqual ([version]'7.4')
    }

    It 'throws AvmConfigurationException when the folder does not exist' {
        $bad = Join-Path $TestDrive 'no-such-module-folder'
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $bad } {
                param($R)
                Test-AvmModuleLayout -ModuleRoot $R
            }
        }
        catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }

    It 'throws AvmConfigurationException when the folder casing is wrong' {
        # Stage a copy of just the .psd1 / .psm1 into a mis-cased folder. We
        # do not need a working module here, just enough for the casing check
        # to fire before Test-ModuleManifest validates anything.
        $bad = Join-Path $TestDrive 'avm.authoring'  # lowercase
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Destination $bad
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Avm.Authoring.psm1') -Destination $bad

        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ R = $bad } {
                param($R)
                # On Windows the OS file-system is case-insensitive so the
                # casing test fires deterministically on the Split-Path leaf
                # rather than on Get-ChildItem.
                Test-AvmModuleLayout -ModuleRoot $R
            }
        }
        catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message | Should -Match "expected 'Avm.Authoring'"
    }
}
