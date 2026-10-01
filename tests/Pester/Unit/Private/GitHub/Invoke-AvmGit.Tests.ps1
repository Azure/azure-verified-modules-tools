#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmGit' {
    It 'runs git without terminal prompts in the requested directory' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/git' } -ParameterFilter { $Name -eq 'git' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = 'abc'; StdErr = '' } }

            $result = Invoke-AvmGit -ArgumentList @('rev-parse', 'HEAD') -WorkingDirectory '/repo'

            $result.StdOut | Should -BeExactly 'abc'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/git' -and $WorkingDirectory -eq '/repo' -and
                ($ArgumentList -join ' ') -eq 'rev-parse HEAD' -and
                -not $IgnoreExitCode -and
                $EnvVars.GIT_TERMINAL_PROMPT -eq '0'
            }
        }
    }

    It 'authenticates through the GitHub CLI only when requested' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmApplicationPath { '/fake/git' } -ParameterFilter { $Name -eq 'git' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' } }

            $null = Invoke-AvmGit -ArgumentList @('push', 'origin', 'HEAD:refs/heads/main') -WorkingDirectory '/repo' `
                -UseGitHubCredential -IgnoreExitCode

            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                ($ArgumentList -join ' ') -eq (
                    '-c credential.helper= -c credential.https://github.com.helper=!gh auth git-credential ' +
                    'push origin HEAD:refs/heads/main') -and
                $IgnoreExitCode
            }
        }
    }
}
