#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Managed files version pin' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    Context 'Get-AvmManagedFilesVersionPinPath' {
        It 'resolves the pin under the .avm folder' {
            InModuleScope 'Avm.Authoring' {
                $path = Get-AvmManagedFilesVersionPinPath -Root 'TestDrive:\repo'
                (Split-Path -Leaf $path) | Should -BeExactly 'managed-files-version.json'
                (Split-Path -Leaf (Split-Path -Parent $path)) | Should -BeExactly '.avm'
            }
        }
    }

    Context 'Set-AvmManagedFilesVersionPin' {
        It 'writes UTF-8 without BOM using LF endings' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'lf-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                $pinPath = (Set-AvmManagedFilesVersionPin -Root $root -Version ([semver]'1.2.3') -Repo 'o/r').Path
                $bytes = [System.IO.File]::ReadAllBytes($pinPath)

                @($bytes | Where-Object { $_ -eq 13 }).Count | Should -Be 0
                $bytes[0] | Should -Not -Be 0xEF
                $bytes[-1] | Should -Be 10
            }
        }

        It 'records provenance and stamps updatedAt when not supplied' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'stamp-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                $result = Set-AvmManagedFilesVersionPin `
                    -Root $root `
                    -Version ([semver]'2.0.1') `
                    -Repo 'Azure/managed' `
                    -Commit '0f1e2d3' `
                    -CommitDate '2026-08-10T14:02:11Z'

                $json = Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json
                $json.version | Should -BeExactly '2.0.1'
                $json.repo | Should -BeExactly 'Azure/managed'
                $json.commit | Should -BeExactly '0f1e2d3'
                $result.UpdatedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            }
        }

        It 'creates the .avm folder when it does not exist' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'fresh-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                $result = Set-AvmManagedFilesVersionPin -Root $root -Version ([semver]'1.0.0') -Repo 'o/r'
                Test-Path -LiteralPath $result.Path -PathType Leaf | Should -BeTrue
            }
        }

        It 'honours -WhatIf' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'whatif-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                $result = Set-AvmManagedFilesVersionPin -Root $root -Version ([semver]'1.0.0') -Repo 'o/r' -WhatIf
                Test-Path -LiteralPath $result.Path -PathType Leaf | Should -BeFalse
            }
        }
    }

    Context 'Get-AvmManagedFilesVersionPin' {
        It 'returns null when the repository is not pinned' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'unpinned-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                Get-AvmManagedFilesVersionPin -Root $root | Should -BeNullOrEmpty
            }
        }

        It 'round-trips a pin written by Set-AvmManagedFilesVersionPin' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'roundtrip-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                Set-AvmManagedFilesVersionPin `
                    -Root $root `
                    -Version ([semver]'1.2.3') `
                    -Repo 'Azure/managed' `
                    -Commit '0f1e2d3' `
                    -CommitDate '2026-08-10T14:02:11Z' | Out-Null

                $pin = Get-AvmManagedFilesVersionPin -Root $root

                $pin.Version | Should -BeOfType ([semver])
                $pin.Version.ToString() | Should -Be '1.2.3'
                $pin.Repo | Should -BeExactly 'Azure/managed'
                $pin.Commit | Should -BeExactly '0f1e2d3'
            }
        }

        It 'preserves ISO 8601 dates that ConvertFrom-Json coerces to DateTime' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'date-repo'
                New-Item -ItemType Directory -Path $root -Force | Out-Null

                Set-AvmManagedFilesVersionPin `
                    -Root $root `
                    -Version ([semver]'1.0.0') `
                    -Repo 'o/r' `
                    -CommitDate '2026-08-10T14:02:11Z' `
                    -UpdatedAt '2026-08-12T09:00:00Z' | Out-Null

                $pin = Get-AvmManagedFilesVersionPin -Root $root

                $pin.CommitDate | Should -BeExactly '2026-08-10T14:02:11Z'
                $pin.UpdatedAt | Should -BeExactly '2026-08-12T09:00:00Z'
            }
        }

        It 'warns and reports unpinned for a malformed pin' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'malformed-repo'
                New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $root '.avm' 'managed-files-version.json') -Value '{ not json'

                Get-AvmManagedFilesVersionPin -Root $root -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }

        It 'reports unpinned when the pin omits a version' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'noversion-repo'
                New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $root '.avm' 'managed-files-version.json') -Value '{"repo":"o/r"}'

                Get-AvmManagedFilesVersionPin -Root $root -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }

        It 'reports unpinned when the version is not valid semver' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'badsemver-repo'
                New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $root '.avm' 'managed-files-version.json') -Value '{"version":"not-a-version"}'

                Get-AvmManagedFilesVersionPin -Root $root -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }

        It 'defaults optional provenance fields to empty strings' {
            InModuleScope 'Avm.Authoring' {
                $root = Join-Path $TestDrive 'minimal-repo'
                New-Item -ItemType Directory -Path (Join-Path $root '.avm') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $root '.avm' 'managed-files-version.json') -Value '{"version":"3.1.4"}'

                $pin = Get-AvmManagedFilesVersionPin -Root $root

                $pin.Version.ToString() | Should -Be '3.1.4'
                $pin.Repo | Should -BeExactly ''
                $pin.Commit | Should -BeExactly ''
                $pin.CommitDate | Should -BeExactly ''
            }
        }
    }
}
