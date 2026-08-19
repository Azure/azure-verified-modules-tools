#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Get-AvmLatestManagedFilesVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'selects the highest semver tag and ignores peeled and non-semver refs' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdErr   = ''
                    StdOut   = @(
                        "aaa`trefs/tags/v0.9.0"
                        "bbb`trefs/tags/v1.10.0"
                        "ccc`trefs/tags/v1.9.0"
                        "ddd`trefs/tags/v2.0.0^{}"
                        "eee`trefs/tags/latest"
                        "fff`trefs/tags/v1.2"
                        "ggg`trefs/heads/main"
                    ) -join "`n"
                }
            }

            $result = Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git'

            $result | Should -BeOfType ([semver])
            $result.ToString() | Should -Be '1.10.0'
        }
    }

    It 'accepts tags published without a leading v' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdErr = ''; StdOut = "aaa`trefs/tags/1.4.2" }
            }

            (Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git').ToString() | Should -Be '1.4.2'
        }
    }

    It 'queries git ls-remote with an argument array over https' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdErr = ''; StdOut = "aaa`trefs/tags/v1.0.0" }
            }

            Get-AvmLatestManagedFilesVersion -Repo 'Azure/managed' -GitPath '/usr/bin/git' | Out-Null

            Should -Invoke Invoke-AvmProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq '/usr/bin/git' -and
                $ArgumentList.Count -eq 3 -and
                $ArgumentList[0] -eq 'ls-remote' -and
                $ArgumentList[1] -eq '--tags' -and
                $ArgumentList[2] -eq 'https://github.com/Azure/managed.git' -and
                $IgnoreExitCode -eq $true
            }
        }
    }

    It 'queries again so a later command observes newly published tags' {
        InModuleScope 'Avm.Authoring' {
            $script:managedFilesLookupCount = 0
            Mock Invoke-AvmProcess {
                $script:managedFilesLookupCount++
                $version = if ($script:managedFilesLookupCount -eq 1) { '1.0.8' } else { '1.0.10' }
                [pscustomobject]@{
                    ExitCode = 0
                    StdErr   = ''
                    StdOut   = "aaa`trefs/tags/v$version"
                }
            }

            $first = Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git'
            $second = Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git'

            $first.ToString() | Should -Be '1.0.8'
            $second.ToString() | Should -Be '1.0.10'
            Should -Invoke Invoke-AvmProcess -Times 2 -Exactly
        }
    }

    It 'throws a lookup exception when git exits non-zero' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 128; StdErr = 'repository not found'; StdOut = '' }
            }

            { Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git' } |
                Should -Throw -ExceptionType ([AvmManagedFilesLookupException])
        }
    }

    It 'throws a lookup exception when no semver tags exist' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdErr = ''; StdOut = "aaa`trefs/heads/main" }
            }

            { Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git' } |
                Should -Throw -ExceptionType ([AvmManagedFilesLookupException])
        }
    }

    It 'throws a lookup exception when git is unavailable' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess { throw 'should not run' }

            { Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath '' } |
                Should -Throw -ExceptionType ([AvmManagedFilesLookupException])
            Should -Invoke Invoke-AvmProcess -Times 0 -Exactly
        }
    }

    It 'wraps a transport failure as a lookup exception' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess { throw [System.TimeoutException]::new('timed out') }

            { Get-AvmLatestManagedFilesVersion -Repo 'o/r' -GitPath 'git' } |
                Should -Throw -ExceptionType ([AvmManagedFilesLookupException])
        }
    }
}
