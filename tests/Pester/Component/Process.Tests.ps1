#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Canary for the Component tier (spec section 18). Exercises Invoke-AvmProcess
# end-to-end against a real subprocess (pwsh itself) and a real TestDrive
# filesystem -- no mocks. If this file is the only thing in the Component/
# tree on a given commit, that's fine: it proves the tier is wired into the
# build/CI graph. Engine-level integration tests land alongside their
# stub-binary harnesses in tests/fixtures/bin/.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $script:moduleManifest -Force

    # Resolve pwsh on PATH so the test is portable across runners.
    $script:pwshPath = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
}

AfterAll {
    Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Invoke-AvmProcess against a real subprocess' -Tag 'Component' {

    It 'captures stdout from a real pwsh invocation' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Pwsh = $script:pwshPath } {
            param($Pwsh)
            Invoke-AvmProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', "'avm-integration-canary'")
        }

        $result.ExitCode | Should -Be 0
        ($result.StdOut.Trim()) | Should -Be 'avm-integration-canary'
        $result.StdErr | Should -BeNullOrEmpty
    }

    It 'propagates a non-zero exit code as AvmProcessException' {
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ Pwsh = $script:pwshPath } {
            param($Pwsh)
            try {
                Invoke-AvmProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', 'exit 7')
                return $null
            }
            catch {
                return $_.Exception
            }
        }

        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.ExitCode | Should -Be 7
    }

    It 'writes to and reads from a real TestDrive path end-to-end' {
        $payload = 'component-tier-canary-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $outFile = Join-Path $TestDrive 'canary.txt'

        $cmd = "Set-Content -LiteralPath '$($outFile -replace "'", "''")' -Value '$payload' -Encoding utf8 -NoNewline"

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Pwsh = $script:pwshPath; Command = $cmd } {
            param($Pwsh, $Command)
            Invoke-AvmProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $Command)
        }

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $outFile | Should -BeTrue
        (Get-Content -LiteralPath $outFile -Raw) | Should -Be $payload
    }
}
