#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Get-AvmVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'returns a single pscustomobject' {
        $result = Get-AvmVersion
        $result | Should -BeOfType [pscustomobject]
        @($result).Count | Should -Be 1
    }

    It 'reports Module=Avm.Authoring (exact casing)' {
        (Get-AvmVersion).Module | Should -BeExactly 'Avm.Authoring'
    }

    It 'reports a non-empty Version' {
        (Get-AvmVersion).Version | Should -Not -BeNullOrEmpty
    }

    It 'reports the loaded module Version, not "unknown"' {
        $loaded = Get-Module -Name 'Avm.Authoring'
        (Get-AvmVersion).Version | Should -Be $loaded.Version.ToString()
    }

    It 'reports OS in the allowed set' {
        (Get-AvmVersion).OS | Should -BeIn @('windows', 'linux', 'macos')
    }

    It 'reports PSEdition=Core' {
        (Get-AvmVersion).PSEdition | Should -Be 'Core'
    }

    It 'reports a non-empty Architecture' {
        (Get-AvmVersion).Architecture | Should -Not -BeNullOrEmpty
    }

    It 'PSVersion parses as a System.Version' {
        { [version](Get-AvmVersion).PSVersion } | Should -Not -Throw
    }
}

Describe 'avm version (dispatcher)' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'routes "avm version" to Get-AvmVersion' {
        $direct = Get-AvmVersion
        $via = avm version
        $via.Module | Should -BeExactly $direct.Module
        $via.Version | Should -Be $direct.Version
    }

    It 'errors on an unknown verb' {
        { avm nope } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'with no arguments, prints help and returns nothing' {
        # Help is emitted via Write-Information; the return value is $null.
        $result = avm 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'lists the tool verbs in the help text' {
        $info = avm 6>&1 | Out-String
        $info | Should -Match 'tool list'
        $info | Should -Match 'tool which'
        $info | Should -Match 'tool install'
    }
}
