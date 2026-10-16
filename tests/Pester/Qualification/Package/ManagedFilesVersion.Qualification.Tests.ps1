#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: managed-files version pin against the real repository' -Tag Qualification {
BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:moduleManifest -Force
    }

AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

It 'discovers the newest release tag through git ls-remote' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        $latest = InModuleScope 'Avm.Authoring' {
            $git = (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -First 1).Source
            if (-not $git) { throw 'git is required for the managed-files version integration test.' }
            Get-AvmLatestManagedFilesVersion `
                -Repo 'Azure/azure-verified-modules-managed-files' `
                -GitPath $git
        }

        $latest | Should -Not -BeNullOrEmpty
        $latest | Should -BeOfType ([semver])
        $latest | Should -BeGreaterOrEqual ([semver]'0.1.0')
    }
}
