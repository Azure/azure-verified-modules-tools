#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Spec section 6.2: every filesystem must be treated as case-sensitive.
# This canary creates a real case collision (Foo.txt + foo.txt in one
# directory, plus a fake module with case-colliding manifests) and
# proves that:
#   1. Linux can host case-colliding files (sanity).
#   2. -ceq is the only reliable picker (Test-Path is not).
#   3. The Test-AvmModuleLayout resolver still picks the correctly
#      cased manifest when a collision exists, i.e. no regression to
#      a silent wrong-file pick.
#
# Windows / macOS default filesystems (NTFS / APFS) are case-INsensitive,
# so a second file with the same casefolded name would replace the first
# on disk. The whole Describe is skipped off-Linux.

Describe 'Spec section 6.2 case-collision canary (Linux only)' -Skip:(-not $IsLinux) {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $script:manifestPath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:manifestPath -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    Context 'Raw filesystem behaviour' {
        BeforeAll {
            $script:collidingDir = Join-Path $TestDrive 'case-collision-raw'
            New-Item -ItemType Directory -Path $script:collidingDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:collidingDir 'Foo.txt') -Value 'upper' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:collidingDir 'foo.txt') -Value 'lower' -NoNewline
        }

        It 'actually creates two distinct files differing only in case' {
            $names = (Get-ChildItem -Path $script:collidingDir -File).Name
            @($names).Count    | Should -Be 2
            $names -ccontains 'Foo.txt' | Should -BeTrue
            $names -ccontains 'foo.txt' | Should -BeTrue
        }

        It 'the two files carry different content (proving the collision is real, not a hardlink)' {
            (Get-Content -LiteralPath (Join-Path $script:collidingDir 'Foo.txt') -Raw) | Should -Be 'upper'
            (Get-Content -LiteralPath (Join-Path $script:collidingDir 'foo.txt') -Raw) | Should -Be 'lower'
        }

        It 'Get-ChildItem | Where -ceq picks exactly the requested casing' {
            $upper = Get-ChildItem -Path $script:collidingDir -File | Where-Object { $_.Name -ceq 'Foo.txt' }
            $lower = Get-ChildItem -Path $script:collidingDir -File | Where-Object { $_.Name -ceq 'foo.txt' }

            @($upper).Count | Should -Be 1
            @($lower).Count | Should -Be 1
            $upper.Name     | Should -BeExactly 'Foo.txt'
            $lower.Name     | Should -BeExactly 'foo.txt'
            (Get-Content -LiteralPath $upper.FullName -Raw) | Should -Be 'upper'
            (Get-Content -LiteralPath $lower.FullName -Raw) | Should -Be 'lower'
        }
    }

    Context 'Test-AvmModuleLayout resolver against a colliding fake module' {
        BeforeAll {
            # Stage a fake module whose folder name matches Avm.Authoring,
            # then create a second manifest + .psm1 with collided casing
            # alongside the canonical pair. The resolver must still pick
            # the correctly-cased Avm.Authoring.psd1.
            $script:fakeRoot = Join-Path $TestDrive 'fake-module' 'Avm.Authoring'
            New-Item -ItemType Directory -Path $script:fakeRoot -Force | Out-Null

            $manifestBody = @'
@{
    RootModule        = 'Avm.Authoring.psm1'
    ModuleVersion     = '0.0.1'
    GUID              = 'a0c5b3c0-d8f8-4e2c-9b9e-8f0a8e0d1234'
    Author            = 'AVM tests'
    CompanyName       = 'Microsoft'
    Copyright         = '(c) Microsoft. All rights reserved.'
    Description       = 'Case-collision fixture for spec section 6.2.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @()
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
'@
            Set-Content -LiteralPath (Join-Path $script:fakeRoot 'Avm.Authoring.psd1') -Value $manifestBody -NoNewline
            Set-Content -LiteralPath (Join-Path $script:fakeRoot 'Avm.Authoring.psm1') -Value '# canonical' -NoNewline

            # The collision: a wrong-cased twin of the manifest and the
            # module file in the same directory.
            Set-Content -LiteralPath (Join-Path $script:fakeRoot 'avm.authoring.psd1') -Value '@{ should = ''never load'' }' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:fakeRoot 'avm.authoring.psm1') -Value '# wrong-cased twin' -NoNewline
        }

        It 'staged the collision (4 files: canonical + wrong-cased pair)' {
            $names = (Get-ChildItem -Path $script:fakeRoot -File).Name
            @($names).Count                       | Should -Be 4
            $names -ccontains 'Avm.Authoring.psd1' | Should -BeTrue
            $names -ccontains 'Avm.Authoring.psm1' | Should -BeTrue
            $names -ccontains 'avm.authoring.psd1' | Should -BeTrue
            $names -ccontains 'avm.authoring.psm1' | Should -BeTrue
        }

        It 'Test-AvmModuleLayout still picks the correctly cased manifest' {
            $manifest = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:fakeRoot } {
                param($Root)
                Test-AvmModuleLayout -ModuleRoot $Root -ExpectedFolderName 'Avm.Authoring'
            }
            $manifest                  | Should -Not -BeNullOrEmpty
            $manifest.Name             | Should -BeExactly 'Avm.Authoring'
            $manifest.Version.ToString() | Should -Be '0.0.1'
        }
    }
}
