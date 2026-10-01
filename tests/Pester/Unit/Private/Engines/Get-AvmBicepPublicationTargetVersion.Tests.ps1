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

    It 'fails if the tracking main ref is stale rather than calculating a false target' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $script:upstreamSha = 'b' * 40
            { Get-AvmBicepPublicationGitState -RepositoryRoot $R } |
                Should -Throw '*tracking ref is stale*'
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

    It 'fails when a repository remote is not the exact upstream identity' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            $script:upstreamUrl = 'https://github.com/Other/bicep-registry-modules.git'
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = if ($ArgumentList[0] -eq 'remote' -and
                        $ArgumentList[2] -eq 'upstream') { 0 } else { 2 }
                    StdOut = if ($ArgumentList[0] -eq 'remote' -and
                        $ArgumentList[2] -eq 'upstream') { $script:upstreamUrl } else { '' }
                    StdErr = ''
                }
            }
            { Get-AvmBicepPublicationGitState -RepositoryRoot $R } |
                Should -Throw '*trusted Azure/bicep-registry-modules*'
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -eq 'ls-remote'
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
