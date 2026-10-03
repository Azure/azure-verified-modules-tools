BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryCandidate.ps1')
}

Describe 'Repository candidate archive and patch' -Tag Component {
    It 'rehydrates and reapplies the exact prepared Git tree without a remote repository' {
        $original = Join-Path $TestDrive 'original'
        $candidate = Join-Path $TestDrive 'candidate'
        $validation = Join-Path $TestDrive 'validation'
        $publication = Join-Path $TestDrive 'publication'
        $null = New-Item -ItemType Directory -Path $original, $candidate, $validation
        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('init', '--quiet', '-b', 'main', $original)
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('config', '--local', 'core.autocrlf', 'false')
        [System.IO.File]::WriteAllText((Join-Path $original '.gitattributes'), "* text=auto eol=lf`n")
        [System.IO.File]::WriteAllText((Join-Path $original 'main.tf'), "variable `"name`" {}`n")
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('add', '--all')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Base')
        $baseSha = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD')

        [System.IO.File]::WriteAllText((Join-Path $original 'main.tf'), "variable `"name`" { type = string }`n")
        [System.IO.File]::WriteAllText((Join-Path $original 'variables.tf'), "variable `"location`" { type = string }`n")
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('add', '--all')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Candidate')
        $tree = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD^{tree}')
        $archivePath = Join-Path $candidate 'candidate.tar'
        $patchPath = Join-Path $candidate 'candidate.patch'
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('archive', '--format=tar', "--output=$archivePath", 'HEAD')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            'diff', '--binary', '--full-index', '--no-renames', "--output=$patchPath", $baseSha, 'HEAD')

        $extract = Invoke-RepositorySyncProcess -Command tar -Arguments @('-xf', $archivePath, '-C', $validation)
        $extract.ExitCode | Should -Be 0
        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('init', '--quiet', '-b', 'main', $validation)
        $null = Invoke-RepositoryGit -WorkingDirectory $validation -Arguments @('config', '--local', 'core.autocrlf', 'false')
        $null = Invoke-RepositoryGit -WorkingDirectory $validation -Arguments @('add', '--all', '--force')
        (Invoke-RepositoryGit -WorkingDirectory $validation -Arguments @('write-tree')) | Should -BeExactly $tree

        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('clone', '--quiet', $original, $publication)
        $null = Invoke-RepositoryGit -WorkingDirectory $publication -Arguments @('checkout', '--quiet', $baseSha)
        $null = Invoke-RepositoryGit -WorkingDirectory $publication -Arguments @('apply', '--index', '--binary', '--', $patchPath)
        (Invoke-RepositoryGit -WorkingDirectory $publication -Arguments @('write-tree')) | Should -BeExactly $tree
    }
}
