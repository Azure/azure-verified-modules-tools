#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'bicep-workflows' 'Release.ps1')
    $script:savedEnvironment = @{}
    foreach ($name in @('GITHUB_REPOSITORY', 'GITHUB_REF', 'GITHUB_TOKEN')) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:modulePath = 'avm/res/mock/widget'
    $script:target = 'a' * 40
    $script:base = 'b' * 40
}

AfterAll {
    foreach ($name in $script:savedEnvironment.Keys) {
        $value = $script:savedEnvironment[$name]
        [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
    }
}

Describe 'Component: Bicep workflow release-tag safeguards' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $script:root $script:modulePath
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $folder 'main.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $folder 'version.json'), '{"version":"1.2"}')
        $env:GITHUB_REPOSITORY = 'Azure/bicep-registry-modules'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_TOKEN = 'fixture-not-a-real-token'
        $script:remote = 'https://github.com/Azure/bicep-registry-modules'
        $script:head = $script:target
        $script:previousVersion = '{"version":"1.2"}'
        $script:diff = "$script:modulePath/main.json"
        $script:remoteTags = ''
        $script:pushExitCode = 0
        $script:concurrentTarget = ''
        Mock Invoke-AvmWorkflowGitRead {
            $code = 0
            $output = switch ($Arguments[0]) {
                'rev-parse' {
                    if ($Arguments[1] -eq '-q') { $code = 1; '' } else { $script:head }
                }

                'remote' { $script:remote }
                'status' { '' }
                'cat-file' { '' }
                'diff' { $script:diff }
                'show' { $script:previousVersion }
                'ls-remote' { $script:remoteTags }
                'check-ref-format' { '' }
                default { throw "Unexpected Git read: $($Arguments[0])" }
            }
            [pscustomobject]@{ ExitCode = $code; StdOut = [string]$output; StdErr = '' }
        }
        Mock Invoke-AvmWorkflowProcess {
            if ($ArgumentList[0] -notin @('tag', 'push')) { throw "Unexpected Git mutation: $($ArgumentList[0])" }
            if ($ArgumentList[0] -eq 'push') {
                if ($script:concurrentTarget) {
                    $script:remoteTags = "$script:concurrentTarget`trefs/tags/$script:modulePath/1.2.0"
                }
                [pscustomobject]@{ ExitCode = $script:pushExitCode; StdOut = ''; StdErr = 'fixture push outcome' }
            }
            else { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        }
    }

    It 'previews proposed tags without creating or pushing them' {
        $result = @(Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -WhatIf)
        $result.Count | Should -Be 1
        $result[0].Tag | Should -BeExactly "$script:modulePath/1.2.0"
        $result[0].Created | Should -BeFalse
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'does not publish metadata-only edits' {
        $script:diff = "$script:modulePath/metadata.json"
        @(Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false).Count |
            Should -Be 0
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'peels annotated tags and reuses an exact already-published target' {
        $script:remoteTags = "$('c' * 40)`trefs/tags/$script:modulePath/1.2.4`n$script:target`trefs/tags/$script:modulePath/1.2.4^{}"
        $result = Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false
        $result.Tag | Should -BeExactly "$script:modulePath/1.2.4"
        $result.Reused | Should -BeTrue
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'increments an existing patch and pushes only the selected tag ref' {
        $script:remoteTags = "$script:base`trefs/tags/$script:modulePath/1.2.4"
        $result = Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false
        $result.Tag | Should -BeExactly "$script:modulePath/1.2.5"
        $result.Created | Should -BeTrue
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'push' -and $ArgumentList[2] -ceq "refs/tags/$script:modulePath/1.2.5:refs/tags/$script:modulePath/1.2.5" -and
            $ArgumentList -notcontains '--force' -and $EnvVars.GIT_CONFIG_COUNT -eq '1'
        }
    }

    It 'resets patch on a major/minor change and refuses an occupied target tag' {
        $script:previousVersion = '{"version":"0.9"}'
        $script:remoteTags = "$script:base`trefs/tags/$script:modulePath/1.2.0"
        { Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false } |
            Should -Throw '*different commit*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'reconciles a failed push once without replaying mutations' {
        $script:pushExitCode = 1
        $script:concurrentTarget = $script:target
        $result = Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false
        $result.Created | Should -BeTrue
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'push' }
        Should -Invoke Invoke-AvmWorkflowGitRead -Exactly 2 -ParameterFilter { $Arguments[0] -eq 'ls-remote' }
    }

    It 'retains a failed push when the remote does not confirm the same target' {
        $script:pushExitCode = 1
        $script:concurrentTarget = $script:base
        { Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false } |
            Should -Throw '*no mutation was retried*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'push' }
    }

    It 'reconciles a timed-out push without replaying it' {
        Mock Invoke-AvmWorkflowProcess {
            $script:remoteTags = "$script:target`trefs/tags/$script:modulePath/1.2.0"
            throw [TimeoutException]::new('fixture push timeout')
        } -ParameterFilter { $ArgumentList[0] -eq 'push' }
        $result = Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false
        $result.Created | Should -BeTrue
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'push' }
    }

    It 'does not promote a missing-base preview fallback into publication' {
        { Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -IncludeAllVersionedModules -Confirm:$false } |
            Should -Throw '*preview-only*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'rejects modified module inputs and a conflicting local tag' {
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = ' M main.json'; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'status' }
        { Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false } |
            Should -Throw '*unchanged from the target*'
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'status' }
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = $script:base; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'rev-parse' -and $Arguments[1] -eq '-q' }
        { Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -Confirm:$false } |
            Should -Throw '*Local tag*different commit*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'uses the target parent for ordinary per-module publication' {
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = $script:base; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'rev-parse' -and $Arguments[1] -eq '--verify' }
        $null = Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -WhatIf
        Should -Invoke Invoke-AvmWorkflowGitRead -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'diff' -and $Arguments -ccontains $script:base -and $Arguments -ccontains $script:target
        }
    }

    It 'requires the upstream main context, expected remote and exact inspected target' {
        $parameters = @{ Root = $script:root; ModulePath = $script:modulePath; TargetCommit = $script:target; BaseCommit = $script:base; WhatIf = $true }
        $env:GITHUB_REF = 'refs/heads/feature'
        { Set-AvmWorkflowReleaseTags @parameters } | Should -Throw '*main branch*'
        $env:GITHUB_REF = 'refs/heads/main'
        $script:remote = 'https://example.invalid/repository'
        { Set-AvmWorkflowReleaseTags @parameters } | Should -Throw '*upstream registry HTTPS*'
        $script:remote = 'https://github.com/Azure/bicep-registry-modules'
        $script:head = $script:base
        { Set-AvmWorkflowReleaseTags @parameters } | Should -Throw '*exact target commit*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'rejects option-shaped commit inputs before invoking Git' {
        { Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit '--help' -WhatIf } |
            Should -Throw '*full SHA-1*'
        Should -Invoke Invoke-AvmWorkflowGitRead -Exactly 0
    }

    It 'orders changed versioned children before the parent' {
        $child = Join-Path $script:root $script:modulePath 'child'
        $null = New-Item -ItemType Directory -Path $child
        [IO.File]::WriteAllText((Join-Path $child 'main.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $child 'version.json'), '{"version":"1.2"}')
        $script:diff = "$script:modulePath/main.json`n$script:modulePath/child/main.json"
        $result = @(Set-AvmWorkflowReleaseTags -Root $script:root -ModulePath $script:modulePath -TargetCommit $script:target -BaseCommit $script:base -WhatIf)
        $result.Module | Should -Be @("$script:modulePath/child", $script:modulePath)
    }
}

Describe 'Component: Bicep pending release discovery' -Tag Component {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force

        function Invoke-AvmReleaseFixtureGit {
            param([string[]] $Arguments)
            $result = Invoke-AvmWorkflowGitRead -Root $script:releaseRoot -Arguments (
                @('-c', 'user.name=WorkflowFixture', '-c', 'user.email=fixture@example.invalid',
                    '-c', 'commit.gpgsign=false') + $Arguments)
            return $result.StdOut.Trim()
        }

        function New-AvmReleaseFixtureCommit {
            param([string] $Message)
            $null = Invoke-AvmReleaseFixtureGit -Arguments @('add', '--all')
            $null = Invoke-AvmReleaseFixtureGit -Arguments @('commit', '--quiet', '-m', $Message)
            return Invoke-AvmReleaseFixtureGit -Arguments @('rev-parse', 'HEAD')
        }

        function Set-AvmReleaseFixtureFile {
            param([string] $Path, [string] $Value)
            $file = Join-Path $script:releaseRoot $Path
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $file -Parent) -Force
            [IO.File]::WriteAllText($file, $Value)
        }
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
        foreach ($folder in $script:releaseFixtures) {
            Get-ChildItem -LiteralPath (Join-Path $folder '.git') -File -Recurse -Force |
                ForEach-Object { $_.IsReadOnly = $false }
        }
    }

    BeforeEach {
        if (-not (Get-Variable -Name releaseFixtures -Scope Script -ErrorAction SilentlyContinue)) {
            $script:releaseFixtures = [Collections.Generic.List[string]]::new()
        }
        $script:releaseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:releaseRoot
        $script:releaseFixtures.Add($script:releaseRoot)
        $env:GITHUB_REPOSITORY = 'Azure/bicep-registry-modules'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_TOKEN = ''
        $script:releaseTags = @{}
        Mock Invoke-AvmWorkflowProcess {
            $records = foreach ($entry in $script:releaseTags.GetEnumerator()) {
                "$($entry.Value)`trefs/tags/$($entry.Key)"
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $records -join "`n"; StdErr = '' }
        } -ParameterFilter { $ArgumentList[0] -eq 'ls-remote' }
        Mock Invoke-AvmWorkflowProcess { throw 'Release discovery must not mutate Git or execute protected tools.' } -ParameterFilter {
            $FilePath -ne 'git' -or $ArgumentList[0] -in @('push', 'tag', 'fetch')
        }
        $null = Invoke-AvmReleaseFixtureGit -Arguments @('init', '--quiet', '--initial-branch=main')
        $null = Invoke-AvmReleaseFixtureGit -Arguments @('config', 'core.autocrlf', 'false')
        $null = Invoke-AvmReleaseFixtureGit -Arguments @('remote', 'add', 'origin', 'https://github.com/Azure/bicep-registry-modules')
        foreach ($path in @($script:modulePath, "$script:modulePath/child")) {
            Set-AvmReleaseFixtureFile -Path "$path/main.bicep" -Value "metadata name = 'fixture'"
            Set-AvmReleaseFixtureFile -Path "$path/main.json" -Value '{"resources":[]}'
            Set-AvmReleaseFixtureFile -Path "$path/version.json" -Value '{"version":"1.2"}'
        }
        $script:initialReleaseCommit = New-AvmReleaseFixtureCommit -Message initial
        $script:releaseTags["$script:modulePath/1.2.2"] = $script:initialReleaseCommit
        $script:releaseTags["$script:modulePath/child/1.2.4"] = $script:initialReleaseCommit
        $script:releaseTarget = $script:initialReleaseCommit
    }

    It 'finds pending publishable changes older than the latest main commit' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/main.json" -Value '{"resources":[{}]}'
        $null = New-AvmReleaseFixtureCommit -Message 'unreleased compiled change'
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/README.md" -Value 'Later documentation.'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'later unrelated change'
        $matrix = Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch -TargetCommit $script:releaseTarget
        $matrix.include.modulePath | Should -Be @($script:modulePath)
        $tags = @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf)
        $tags.Tag | Should -Be @("$script:modulePath/1.2.3")
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -in @('push', 'tag') }
    }

    It 'does not release unchanged modules or docs, metadata, source and test-only edits (<ChangedFile>)' -ForEach @(
        @{ ChangedFile = '' }
        @{ ChangedFile = 'README.md' }
        @{ ChangedFile = 'metadata.json' }
        @{ ChangedFile = 'main.bicep' }
        @{ ChangedFile = 'tests/unit/main.tests.bicep' }
    ) {
        if ($ChangedFile) {
            Set-AvmReleaseFixtureFile -Path "$script:modulePath/$ChangedFile" -Value 'Not a compiled publication change.'
            $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'nonpublishable change'
        }
        $matrix = Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch -TargetCommit $script:releaseTarget
        $matrix.include | Should -HaveCount 0
        @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf) | Should -HaveCount 0
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -in @('push', 'tag') }
    }

    It 'initially releases untagged versioned modules without a parent-commit fallback or force' {
        $script:releaseTags = @{}
        $tags = @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf)
        $tags.Tag | Should -Be @("$script:modulePath/child/1.2.0", "$script:modulePath/1.2.0")
        $matrix = Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch -TargetCommit $script:releaseTarget
        $matrix.include.modulePath | Should -Be @($script:modulePath)
    }

    It 'keeps child and parent baselines independent when the child was released more recently' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/child/main.json" -Value '{"resources":[{}]}'
        $childRelease = New-AvmReleaseFixtureCommit -Message 'already released child change'
        $script:releaseTags["$script:modulePath/child/1.2.5"] = $childRelease
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/main.json" -Value '{"resources":[{}]}'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'pending parent change'
        $tags = @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf)
        $tags.Tag | Should -Be @("$script:modulePath/1.2.3")
    }

    It 'rechecks source tags after discovery instead of publishing a stale approved selection' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/main.json" -Value '{"resources":[{}]}'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'pending parent change'
        (Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch `
                -TargetCommit $script:releaseTarget).include | Should -HaveCount 1
        $script:releaseTags["$script:modulePath/1.2.3"] = $script:releaseTarget
        @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf) | Should -HaveCount 0
    }

    It 'releases a pending child without re-releasing its already released parent' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/child/main.json" -Value '{"resources":[{}]}'
        $null = New-AvmReleaseFixtureCommit -Message 'pending child change'
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/main.json" -Value '{"resources":[{}]}'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'released parent change'
        $script:releaseTags["$script:modulePath/1.2.3"] = $script:releaseTarget
        $tags = @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf)
        $tags.Tag | Should -Be @("$script:modulePath/child/1.2.5")
        (Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch `
                -TargetCommit $script:releaseTarget).include.modulePath | Should -Be @($script:modulePath)
    }

    It 'orders independently pending children before their parent and resets a changed minor version' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/child/main.json" -Value '{"resources":[{}]}'
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/version.json" -Value '{"version":"1.3"}'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'pending child and minor version'
        $tags = @(Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -WhatIf)
        $tags.Tag | Should -Be @("$script:modulePath/child/1.2.5", "$script:modulePath/1.3.0")
    }

    It 'retains explicit before/after push discovery instead of applying manual pending semantics' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/main.json" -Value '{"resources":[{}]}'
        $before = New-AvmReleaseFixtureCommit -Message 'older pending compiled change'
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/README.md" -Value 'Later documentation.'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'latest docs change'
        (Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName push `
                -TargetCommit $script:releaseTarget -BaseCommit $before).include | Should -HaveCount 0
        (Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName push `
                -TargetCommit $script:releaseTarget -BaseCommit $script:initialReleaseCommit).include.modulePath |
            Should -Be @($script:modulePath)
    }

    It 'fails on unavailable or invalid release history rather than returning a no-op (<Failure>)' -ForEach @(
        @{ Failure = 'missing tag commit' }
        @{ Failure = 'nonancestor tag' }
        @{ Failure = 'shallow history' }
        @{ Failure = 'remote failure' }
    ) {
        switch ($Failure) {
            'missing tag commit' { $script:releaseTags["$script:modulePath/1.2.9"] = 'f' * 40 }
            'nonancestor tag' {
                $null = Invoke-AvmReleaseFixtureGit -Arguments @('checkout', '--quiet', '--orphan', 'unrelated')
                $orphan = New-AvmReleaseFixtureCommit -Message unrelated
                $null = Invoke-AvmReleaseFixtureGit -Arguments @('switch', '--quiet', 'main')
                $script:releaseTags["$script:modulePath/1.2.9"] = $orphan
            }
            'shallow history' {
                Mock Invoke-AvmWorkflowProcess {
                    [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
                } -ParameterFilter { $ArgumentList -contains '--is-shallow-repository' }
            }
            'remote failure' {
                Mock Invoke-AvmWorkflowProcess { throw [InvalidOperationException]::new('Unavailable remote tags.') } -ParameterFilter {
                    $ArgumentList[0] -eq 'ls-remote'
                }
            }
        }
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch `
                -TargetCommit $script:releaseTarget } | Should -Throw
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -in @('push', 'tag') }
    }

    It 'rejects missing push history and unsupported or nonupstream contexts without publication' {
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName push -TargetCommit $script:releaseTarget } |
            Should -Throw '*full commit identifiers*'
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName pull_request -TargetCommit $script:releaseTarget } |
            Should -Throw
        $env:GITHUB_REF = 'refs/heads/feature'
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch -TargetCommit $script:releaseTarget } |
            Should -Throw '*main branch*'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_REPOSITORY = 'fork/bicep-registry-modules'
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch -TargetCommit $script:releaseTarget } |
            Should -Throw '*main branch*'
    }

    It 'rejects dirty discovery inputs and tags that do not contain their versioned module' {
        Set-AvmReleaseFixtureFile -Path "$script:modulePath/main.json" -Value '{"resources":[{}]}'
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch `
                -TargetCommit $script:releaseTarget } | Should -Throw '*unchanged from the target*'
        $script:releaseTarget = New-AvmReleaseFixtureCommit -Message 'pending compiled change'
        Mock Invoke-AvmWorkflowProcess {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Missing version at tagged commit.' }
        } -ParameterFilter { $ArgumentList[0] -eq 'cat-file' -and $ArgumentList[-1] -like '*:*/version.json' }
        { Initialize-AvmWorkflowReleaseMatrix -Root $script:releaseRoot -EventName workflow_dispatch `
                -TargetCommit $script:releaseTarget } | Should -Throw '*Missing version*'
    }

    It 'does not allow a pending release to force a module or override its tag baseline' {
        { Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -Force -WhatIf } | Should -Throw '*cannot override*'
        { Set-AvmWorkflowReleaseTags -Root $script:releaseRoot -ModulePath $script:modulePath `
                -TargetCommit $script:releaseTarget -PendingRelease -BaseCommit $script:initialReleaseCommit -WhatIf } |
            Should -Throw '*cannot override*'
    }
}
