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
