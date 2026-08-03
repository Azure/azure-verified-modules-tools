#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Assert-AvmGitWorkingTreeClean' {
    It 'passes when git status porcelain output is empty' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Command {
                [pscustomobject]@{ Source = '/fake/git' }
            } -ParameterFilter { $Name -eq 'git' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            { Assert-AvmGitWorkingTreeClean -Path '/repo' } | Should -Not -Throw
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/git' -and
                $WorkingDirectory -eq '/repo' -and
                $ArgumentList.Count -eq 2 -and
                $ArgumentList[0] -eq 'status' -and
                $ArgumentList[1] -eq '--porcelain'
            }
        }
    }

    It 'rejects tracked and untracked changes with remediation guidance' {
        $probe = InModuleScope 'Avm.Authoring' {
            Mock Get-Command {
                [pscustomobject]@{ Source = '/fake/git' }
            } -ParameterFilter { $Name -eq 'git' }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = " M main.tf`n?? generated.tf"
                    StdErr = ''
                }
            }

            try {
                Assert-AvmGitWorkingTreeClean -Path '/repo'
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message = $_.Exception.Message
                }
            }
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'clean working tree'
        $probe.Message | Should -Match 'main\.tf'
        $probe.Message | Should -Match 'generated\.tf'
        $probe.Message | Should -Match 'Commit, stash, or remove'
    }

    It 'reports a configuration error when git is unavailable' {
        $probe = InModuleScope 'Avm.Authoring' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'git' }

            try {
                Assert-AvmGitWorkingTreeClean -Path '/repo'
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message = $_.Exception.Message
                }
            }
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'git was not found'
    }
}
