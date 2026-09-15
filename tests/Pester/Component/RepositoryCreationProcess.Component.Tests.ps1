#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts' 'RepositoryCreation.ps1')
    $processModule = Import-AvmRepositoryCreationModule
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: repository creation metadata process boundary' -Tag Component {
    It 'uses the checked-out process helper with resolved executables and intact argv' {
        Mock Get-Command {
            [pscustomobject]@{ Source = 'resolved-git' }
            [pscustomobject]@{ Source = 'ignored-git' }
        } -ParameterFilter { $Name -eq 'git' }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            [pscustomobject]@{ ExitCode = 0; StdOut = 'local result'; StdErr = '' }
        }

        $result = Invoke-AvmRepositoryCreationProcess -AuthoringModule $processModule -Tool git `
            -ArgumentList @('commit', '-m', 'literal message with spaces & punctuation') -WorkingDirectory $TestDrive

        $result.StdOut | Should -Be 'local result'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'resolved-git' -and $ArgumentList.Count -eq 3 -and
            $ArgumentList[2] -ceq 'literal message with spaces & punctuation'
        }
    }

    It 'surfaces subprocess errors without command or installed-module fallbacks' {
        Mock Get-Command { [pscustomobject]@{ Source = 'resolved-gh' } } -ParameterFilter { $Name -eq 'gh' }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            throw [System.InvalidOperationException]::new('Permission denied by GitHub.')
        }

        { Invoke-AvmRepositoryCreationProcess -AuthoringModule $processModule -Tool gh `
                -ArgumentList @('auth', 'status') -WorkingDirectory $TestDrive } |
            Should -Throw '*Permission denied by GitHub*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Times 1 -Exactly
    }

    It 'initializes a local main branch with the Git-specific init-db command' {
        $repositoryPath = Join-Path $TestDrive 'new repository'
        $result = Invoke-AvmRepositoryCreationProcess -AuthoringModule $processModule -Tool git `
            -ArgumentList @('init-db', '--quiet', '--initial-branch=main', $repositoryPath) -WorkingDirectory $TestDrive
        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $repositoryPath '.git') -PathType Container | Should -BeTrue
        $branch = Invoke-AvmRepositoryCreationProcess -AuthoringModule $processModule -Tool git `
            -ArgumentList @('symbolic-ref', 'HEAD') -WorkingDirectory $repositoryPath
        $branch.StdOut.Trim() | Should -Be 'refs/heads/main'
    }
}
