#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'avm disable sentinel (.avm/.disable)' {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ('disable-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:repo '.avm') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $script:repo '.avm') '.disable') -Value '' -NoNewline
        $script:nested = Join-Path (Join-Path $script:repo 'src') 'project'
        New-Item -ItemType Directory -Path $script:nested -Force | Out-Null
        $script:origCwd = (Get-Location).Path
    }

    AfterEach {
        Set-Location -LiteralPath $script:origCwd
    }

    It 'Test-AvmDisableSentinel finds the sentinel from the repo root' {
        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:repo } {
            param($P)
            Test-AvmDisableSentinel -Path $P
        }
        $found | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $found | Should -BeTrue
    }

    It 'Test-AvmDisableSentinel walks up from a nested subdirectory' {
        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:nested } {
            param($P)
            Test-AvmDisableSentinel -Path $P
        }
        $found | Should -Not -BeNullOrEmpty
    }

    It 'Test-AvmDisableSentinel returns $null when no sentinel exists' {
        $clean = Join-Path $TestDrive ('clean-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $clean -Force | Out-Null
        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $clean } {
            param($P)
            Test-AvmDisableSentinel -Path $P
        }
        $found | Should -BeNullOrEmpty
    }

    It 'dispatcher throws AvmConfigurationException when the sentinel is present' {
        Set-Location -LiteralPath $script:nested
        $err = $null
        try { avm version } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Code | Should -Be 'AVM1001'
        $err.Message | Should -Match 'disabled in this repository'
    }
}
