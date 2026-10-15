BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
    $script:managedPath = '.github/skills/avm-tf-azapi/scripts/Get-AzureSchema.ps1'
}

Describe 'Repository sync staging of added managed files' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        [System.IO.File]::WriteAllText((Join-Path $script:root '.gitignore'), "scripts`n*.tfvars`n")
        git -C $script:root init --quiet -b main
        git -C $script:root add -- .gitignore
        $identityNames = @('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL')
        $previousIdentity = @{}
        foreach ($name in $identityNames) {
            $previousIdentity[$name] = [System.Environment]::GetEnvironmentVariable($name)
        }
        try {
            $env:GIT_AUTHOR_NAME = 'AVM test'
            $env:GIT_AUTHOR_EMAIL = 'avm-test@example.invalid'
            $env:GIT_COMMITTER_NAME = $env:GIT_AUTHOR_NAME
            $env:GIT_COMMITTER_EMAIL = $env:GIT_AUTHOR_EMAIL
            git -C $script:root commit --quiet -m 'Base'
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to commit the managed-file staging fixture.'
            }
        }
        finally {
            foreach ($name in $identityNames) {
                if ($null -eq $previousIdentity[$name]) {
                    [System.Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
                }
                else {
                    [System.Environment]::SetEnvironmentVariable($name, $previousIdentity[$name], 'Process')
                }
            }
        }
        $managed = Join-Path $script:root ($script:managedPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $managed) -Force
        [System.IO.File]::WriteAllText($managed, "Write-Output 'managed'`n")
        $null = New-Item -ItemType Directory -Path (Join-Path $script:root 'scripts') -Force
        [System.IO.File]::WriteAllText((Join-Path $script:root 'scripts' 'local.tfvars'), "example = `"placeholder`"`n")
        $script:result = [pscustomobject]@{
            Steps = @([pscustomobject]@{
                    Step = 'sync'
                    Status = 'pass'
                    Result = [pscustomobject]@{ Added = @($script:managedPath) }
                })
        }
    }

    It 'stages the newly generated managed file without staging unrelated ignored files' {
        Add-RepositorySyncManagedFiles -Root $script:root -PreCommitResult $script:result

        @(git -C $script:root diff --cached --name-only) | Should -Be @($script:managedPath)
        @(git -C $script:root status --short --untracked-files=all) | Should -Be @("A  $($script:managedPath)")
        @(git -C $script:root ls-files --cached -- scripts/local.tfvars) | Should -BeNullOrEmpty
    }

    It 'rejects unsafe or absent managed-file paths before staging anything' {
        foreach ($path in @('../local.tfvars', '.github/skills/missing.ps1')) {
            $script:result.Steps[0].Result.Added = @($script:managedPath, $path)
            { Add-RepositorySyncManagedFiles -Root $script:root -PreCommitResult $script:result } | Should -Throw
            @(git -C $script:root diff --cached --name-only) | Should -BeNullOrEmpty
        }
    }

    It 'does not stage ignored files when the managed-file sync added nothing' {
        $script:result.Steps[0].Result.Added = @()
        Add-RepositorySyncManagedFiles -Root $script:root -PreCommitResult $script:result
        @(git -C $script:root diff --cached --name-only) | Should -BeNullOrEmpty
    }
}
