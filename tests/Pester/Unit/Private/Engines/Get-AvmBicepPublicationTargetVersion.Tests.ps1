#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).ProviderPath
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep publication Git provenance' -Tag 'Unit' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:publicationSha = 'a' * 40
            $script:upstreamSha = 'a' * 40
            $script:upstreamUrl = 'https://github.com/Azure/bicep-registry-modules.git'
            Mock Get-Command {
                [pscustomobject]@{ Source = 'mock-git' }
            } -ParameterFilter { $Name -eq 'git' }
            Mock Invoke-AvmProcess {
                $output = switch ($ArgumentList[0]) {
                    'remote' {
                        if ($ArgumentList[2] -eq 'upstream') { $script:upstreamUrl } else { '' }
                    }
                    'rev-parse' { $script:publicationSha }
                    'ls-remote' { "$($script:upstreamSha)`trefs/heads/main`n" }
                    'diff' { "avm/res/mock/widget/main.json`0" }
                    'ls-files' { "avm/res/mock/widget/version.json`0" }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = [string]$output; StdErr = '' }
            }
        }
    }

    It 'requires an exact trusted upstream and current main before reading changed paths' {
        $state = InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            Get-AvmBicepPublicationGitState -RepositoryRoot $R
        }
        $state.BaseSha | Should -Be ('a' * 40)
        $state.ChangedPaths.Count | Should -Be 2
        $state.ChangedPaths.Contains('avm/res/mock/widget/main.json') | Should -BeTrue
        $state.ChangedPaths.Contains('avm/res/mock/widget/version.json') | Should -BeTrue
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'ls-remote' -and $ArgumentList[1] -eq '--heads' -and
                $ArgumentList[2] -eq 'https://github.com/Azure/bicep-registry-modules.git'
            }
        }
    }

    It 'uses pinned current module data when the trusted tracking ref is stale' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $script:upstreamSha = 'b' * 40
            $state = Get-AvmBicepPublicationGitState -RepositoryRoot $R
            $state.BaseSha | Should -BeExactly ('b' * 40)
            $state.RemoteFiles.Count | Should -Be 0
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -eq 'diff' }
        }
    }

    It 'uses a current trusted origin ref when the configured upstream ref is stale' {
        $state = InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $script:upstreamSha = 'b' * 40
            Mock Invoke-AvmProcess {
                $output = switch ($ArgumentList[0]) {
                    'remote' { 'https://github.com/Azure/bicep-registry-modules.git' }
                    'rev-parse' {
                        if ($ArgumentList[-1] -like '*upstream*') { 'a' * 40 } else { 'b' * 40 }
                    }
                    'ls-remote' { "$('b' * 40)`trefs/heads/main" }
                    'diff' { '' }
                    'ls-files' { '' }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = [string]$output; StdErr = '' }
            }
            Get-AvmBicepPublicationGitState -RepositoryRoot $R
        }
        $state.BaseSha | Should -Be ('b' * 40)
    }

    It 'uses pinned public module data when no trusted local checkout exists' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $script:upstreamUrl = 'https://github.com/Other/bicep-registry-modules.git'
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = if ($ArgumentList[0] -eq 'ls-remote' -or
                        ($ArgumentList[0] -eq 'remote' -and $ArgumentList[2] -eq 'upstream')) { 0 } else { 2 }
                    StdOut = if ($ArgumentList[0] -eq 'remote' -and
                        $ArgumentList[2] -eq 'upstream') { $script:upstreamUrl } else { '' }
                    StdErr = ''
                }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = "$('a' * 40)`trefs/heads/main"; StdErr = '' }
            } -ParameterFilter { $ArgumentList[0] -eq 'ls-remote' }
            $state = Get-AvmBicepPublicationGitState -RepositoryRoot $R
            $state.BaseSha | Should -BeExactly ('a' * 40)
            $state.RemoteFiles.Count | Should -Be 0
            $state.ChangedPaths.Count | Should -Be 0
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -in @('clone', 'fetch', 'checkout', 'show', 'ls-tree', 'diff')
            }
        }
    }
}

Describe 'Get-AvmBicepPublicationTargetVersion' -Tag 'Unit' {
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:oldVersion = '{"version":"0.1"}'
            $script:baseEntry = "100644 blob $('b' * 40)`tavm/res/mock/widget/version.json`0"
            $script:releaseTags = @(
                "$('c' * 40)`trefs/tags/avm/res/mock/widget/0.1.0"
                "$('d' * 40)`trefs/tags/avm/res/mock/widget/0.1.4"
            ) -join "`n"
            Mock Invoke-AvmProcess {
                $output = switch ($ArgumentList[0]) {
                    'ls-tree' { $script:baseEntry }
                    'show' { $script:oldVersion }
                    'ls-remote' { $script:releaseTags }
                }

                [pscustomobject]@{ ExitCode = 0; StdOut = [string]$output; StdErr = '' }
            }
        }
    }

    It 'increments the greatest upstream release patch for unchanged major.minor' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $scope = [pscustomobject]@{ ModuleRelativePath = 'avm/res/mock/widget' }
            $state = [pscustomobject]@{
                GitPath = 'mock-git'; RepositoryRoot = $R; BaseSha = 'a' * 40
                ChangedPaths = @('avm/res/mock/widget/main.json')
            }
            Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.1' -GitState $state
        }
        $result.TargetVersion | Should -BeExactly '0.1.5'
        $result.VersionChanged | Should -BeFalse
        $result.ShouldPublish | Should -BeTrue
    }

    It 'resets the target patch when version.json changes without requesting release tags' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $scope = [pscustomobject]@{ ModuleRelativePath = 'avm/res/mock/widget' }
            $state = [pscustomobject]@{
                GitPath = 'mock-git'; RepositoryRoot = $R; BaseSha = 'a' * 40
                ChangedPaths = @('avm/res/mock/widget/version.json')
            }
            Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.2' -GitState $state
        }
        $result.TargetVersion | Should -BeExactly '0.2.0'
        $result.VersionChanged | Should -BeTrue
        $result.PreviousVersion | Should -BeExactly '0.1'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -eq 'ls-remote'
            }
        }
    }

    It 'treats a descendant publishing file as a pending ancestor changelog under the registry rules' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $scope = [pscustomobject]@{ ModuleRelativePath = 'avm/res/mock/widget' }
            $state = [pscustomobject]@{
                GitPath = 'mock-git'; RepositoryRoot = $R; BaseSha = 'a' * 40
                ChangedPaths = @('avm/res/mock/widget/child/main.json')
            }
            Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.1' -GitState $state
        }
        $result.TargetVersion | Should -BeExactly '0.1.5'
        $result.ShouldPublish | Should -BeTrue
    }

    It 'rejects version downgrades and unparseable versions in the trusted baseline' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $scope = [pscustomobject]@{ ModuleRelativePath = 'avm/res/mock/widget' }
            $state = [pscustomobject]@{
                GitPath = 'mock-git'; RepositoryRoot = $R; BaseSha = 'a' * 40
                ChangedPaths = @('avm/res/mock/widget/version.json')
            }
            $script:oldVersion = '{"version":"0.2"}'
            { Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.1' -GitState $state } |
                Should -Throw '*must increase from upstream*'
            $script:oldVersion = '{"version":"0.2147483648"}'
            { Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.1' -GitState $state } |
                Should -Throw '*lacks a valid major.minor*'
        }
    }

    It 'does not treat a malformed or unavailable upstream tag list as zero releases' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $scope = [pscustomobject]@{ ModuleRelativePath = 'avm/res/mock/widget' }
            $state = [pscustomobject]@{
                GitPath = 'mock-git'; RepositoryRoot = $R; BaseSha = 'a' * 40
                ChangedPaths = @()
            }
            $script:releaseTags = "$('c' * 40)`trefs/tags/avm/res/mock/other/0.1.4"
            { Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.1' -GitState $state } |
                Should -Throw '*unexpected format*'
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = if ($ArgumentList[0] -eq 'ls-remote') { 128 } else { 0 }
                    StdOut = if ($ArgumentList[0] -eq 'ls-tree') { $script:baseEntry }
                    elseif ($ArgumentList[0] -eq 'show') { $script:oldVersion }
                    else { '' }
                    StdErr = ''
                }
            }
            { Get-AvmBicepPublicationTargetVersion -Scope $scope -Version '0.1' -GitState $state } |
                Should -Throw '*release tags*unknown*'
        }
    }
}

Describe 'Bicep checkout-free publication data' -Tag 'Unit' {
    BeforeEach {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $script:snapshotRoot = Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:snapshotScope = [pscustomobject]@{
                ModuleRelativePath = 'avm/res/mock/widget'
                Path = Join-Path $script:snapshotRoot 'avm/res/mock/widget'
            }
            $null = New-Item -ItemType Directory -Path $script:snapshotScope.Path -Force
            [IO.File]::WriteAllText((Join-Path $script:snapshotScope.Path 'version.json'), '{"version":"0.1"}')
            [IO.File]::WriteAllText((Join-Path $script:snapshotScope.Path 'main.json'), '{}')
            $script:snapshotState = [pscustomobject]@{
                GitPath = 'mock-git'; RepositoryRoot = $script:snapshotRoot; BaseSha = 'a' * 40
                ChangedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                RemoteFiles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            }
            $script:snapshotStatus = 200
            $script:snapshotVersion = '{"version":"0.1"}'
            $script:snapshotMain = '{}'
            $script:snapshotRedirect = $false
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = $script:snapshotStatus
                    Content = if ($Uri.EndsWith('/version.json')) { $script:snapshotVersion } else { $script:snapshotMain }
                    BaseResponse = [pscustomobject]@{
                        RequestMessage = [pscustomobject]@{
                            RequestUri = [uri]$(if ($script:snapshotRedirect) { 'https://example.invalid/file' } else { $Uri })
                        }
                    }
                }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = "$('b' * 40)`trefs/tags/avm/res/mock/widget/0.1.4"; StdErr = '' }
            }
        }
    }

    It 'compares selected module data and caches pinned files: <Changed>' -ForEach @(
        @{ Changed = $false }, @{ Changed = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Changed = $Changed } {
            param($Changed)
            if ($Changed) { $script:snapshotMain = '{"previous":true}' }
            $result = Get-AvmBicepPublicationTargetVersion -Scope $script:snapshotScope -Version '0.1' -GitState $script:snapshotState
            $result.TargetVersion | Should -BeExactly '0.1.5'
            $result.ShouldPublish | Should -Be $Changed
            $result.PreviousVersion | Should -BeExactly '0.1'
            Should -Invoke Invoke-AvmWebRequest -Exactly 2 -ParameterFilter {
                $Uri.StartsWith("https://raw.githubusercontent.com/Azure/bicep-registry-modules/$('a' * 40)/avm/res/mock/widget/")
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'ls-remote' }
        }
    }

    It 'includes changed descendant publication files when checking a parent' {
        InModuleScope Avm.Authoring {
            $child = Join-Path $script:snapshotScope.Path 'child'
            $null = New-Item -ItemType Directory -Path $child
            [IO.File]::WriteAllText((Join-Path $child 'main.json'), '{"new":true}')
            $result = Get-AvmBicepPublicationTargetVersion -Scope $script:snapshotScope -Version '0.1' -GitState $script:snapshotState
            $result.ShouldPublish | Should -BeTrue
            $script:snapshotState.ChangedPaths.Contains('avm/res/mock/widget/child/main.json') | Should -BeTrue
        }
    }

    It 'rejects untrustworthy upstream module data: <Violation>' -ForEach @(
        @{ Violation = 'unavailable'; Message = '*HTTP 503*' }
        @{ Violation = 'unattributed'; Message = '*pinned endpoint*' }
        @{ Violation = 'false absence'; Message = '*HTTP 404*' }
        @{ Violation = 'downgrade'; Message = '*must increase*' }
        @{ Violation = 'invalid JSON'; Message = '*parse*version.json*' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Violation = $Violation; Message = $Message } {
            param($Violation, $Message)
            switch ($Violation) {
                'unavailable' { $script:snapshotStatus = 503 }
                'unattributed' { $script:snapshotRedirect = $true }
                'false absence' { $script:snapshotStatus = 404; $script:snapshotVersion = '<html>Proxy failure</html>' }
                'downgrade' { $script:snapshotVersion = '{"version":"0.2"}' }
                'invalid JSON' { $script:snapshotVersion = 'broken' }
            }
            { Get-AvmBicepPublicationTargetVersion -Scope $script:snapshotScope -Version '0.1' -GitState $script:snapshotState } |
                Should -Throw $Message
        }
    }
}
