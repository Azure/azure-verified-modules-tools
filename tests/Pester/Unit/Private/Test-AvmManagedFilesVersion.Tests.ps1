#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Test-AvmManagedFilesVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'reports <expected> for pinned {pinned} against latest {latest}' -TestCases @(
        @{ pinned = '1.2.3'; latest = '1.2.3'; expected = 'upToDate' }
        @{ pinned = '1.2.3'; latest = '1.2.9'; expected = 'patch' }
        @{ pinned = '1.2.3'; latest = '1.5.0'; expected = 'minor' }
        @{ pinned = '1.2.3'; latest = '2.0.0'; expected = 'major' }
        @{ pinned = '1.2.3'; latest = '1.0.0'; expected = 'upToDate' }
        @{ pinned = '0.9.0'; latest = '1.0.0'; expected = 'major' }
    ) {
        param($pinned, $latest, $expected)

        InModuleScope 'Avm.Authoring' -Parameters @{ pinned = $pinned; latest = $latest; expected = $expected } {
            $result = Test-AvmManagedFilesVersion -PinnedVersion ([semver]$pinned) -LatestVersion ([semver]$latest)
            $result.Status | Should -BeExactly $expected
        }
    }

    It 'reports unpinned when no pin is present' {
        InModuleScope 'Avm.Authoring' {
            $result = Test-AvmManagedFilesVersion -PinnedVersion $null -LatestVersion ([semver]'1.0.0')

            $result.Status | Should -BeExactly 'unpinned'
            $result.IsBehind | Should -BeFalse
            $result.IsMajorBehind | Should -BeFalse
        }
    }

    It 'reports unknown when the latest version could not be resolved' {
        InModuleScope 'Avm.Authoring' {
            $result = Test-AvmManagedFilesVersion -PinnedVersion ([semver]'1.0.0') -LatestVersion $null

            $result.Status | Should -BeExactly 'unknown'
            $result.IsBehind | Should -BeFalse
            $result.IsMajorBehind | Should -BeFalse
        }
    }

    It 'flags drift and major drift consistently with the status' {
        InModuleScope 'Avm.Authoring' {
            $minor = Test-AvmManagedFilesVersion -PinnedVersion ([semver]'1.2.3') -LatestVersion ([semver]'1.5.0')
            $minor.IsBehind | Should -BeTrue
            $minor.IsMajorBehind | Should -BeFalse

            $major = Test-AvmManagedFilesVersion -PinnedVersion ([semver]'1.2.3') -LatestVersion ([semver]'2.0.0')
            $major.IsBehind | Should -BeTrue
            $major.IsMajorBehind | Should -BeTrue

            $current = Test-AvmManagedFilesVersion -PinnedVersion ([semver]'1.2.3') -LatestVersion ([semver]'1.2.3')
            $current.IsBehind | Should -BeFalse
        }
    }

    It 'echoes the compared versions back to the caller' {
        InModuleScope 'Avm.Authoring' {
            $result = Test-AvmManagedFilesVersion -PinnedVersion ([semver]'1.2.3') -LatestVersion ([semver]'2.0.0')

            $result.PinnedVersion.ToString() | Should -Be '1.2.3'
            $result.LatestVersion.ToString() | Should -Be '2.0.0'
        }
    }
}
