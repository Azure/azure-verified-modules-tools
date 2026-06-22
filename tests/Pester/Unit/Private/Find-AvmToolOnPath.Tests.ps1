#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    # We use 'pwsh' itself as the path-fallback fixture. Get-Command will
    # always resolve it on a host that's running these tests.
    $script:pwshHost = (Get-Process -Id $PID).Path
    $script:pwshVersion = $PSVersionTable.PSVersion.ToString()
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Find-AvmToolOnPath' {
    It 'returns $null when the entrypoint is not on PATH' {
        $result = InModuleScope 'Avm.Authoring' {
            Find-AvmToolOnPath -Entrypoint 'no-such-binary-avm-12345' -ExpectedVersion '1.2.3'
        }
        $result | Should -BeNullOrEmpty
    }

    It 'finds pwsh on PATH and returns its path' {
        # pwsh --version prints e.g. "PowerShell 7.6.1" so the regex matches.
        $expected = $script:pwshVersion
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ V = $expected } {
            param($V)
            Find-AvmToolOnPath -Entrypoint 'pwsh' -ExpectedVersion $V
        }
        $result | Should -Not -BeNullOrEmpty
        $result.Path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.Path | Should -BeTrue
    }

    It 'reports Matches=$true when the detected version equals the expected one' {
        $expected = $script:pwshVersion
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ V = $expected } {
            param($V)
            Find-AvmToolOnPath -Entrypoint 'pwsh' -ExpectedVersion $V
        }
        $result.DetectedVersion | Should -Be $expected
        $result.Matches | Should -BeTrue
    }

    It 'reports Matches=$false when the detected version does not match' {
        $result = InModuleScope 'Avm.Authoring' {
            Find-AvmToolOnPath -Entrypoint 'pwsh' -ExpectedVersion '99.99.99'
        }
        $result.Matches | Should -BeFalse
    }

    It 'tolerates a leading "v" on either side of the version comparison' {
        $expected = 'v' + $script:pwshVersion
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ V = $expected } {
            param($V)
            Find-AvmToolOnPath -Entrypoint 'pwsh' -ExpectedVersion $V
        }
        $result.Matches | Should -BeTrue
    }
}
