#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Resolve-AvmManagedFilesVersionPlan' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'returns the ref unchanged when the version check is skipped' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { throw 'should not be called' }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = $null
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git' -SkipVersionCheck

            $plan.Status | Should -Be 'skipped'
            $plan.Ref | Should -Be 'main'
            $plan.ShouldStamp | Should -BeFalse
            Should -Invoke Get-AvmLatestManagedFilesVersion -Times 0
        }
    }

    It 'returns the ref unchanged when a local managed-files path is in use' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { throw 'should not be called' }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesLocalPath = '/tmp/files'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = $null
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'skipped'
            $plan.Ref | Should -Be 'main'
            Should -Invoke Get-AvmLatestManagedFilesVersion -Times 0
        }
    }

    It 'reports overridden and never looks up the latest version for <Source> refs' -TestCases @(
        @{ Source = 'explicit' }
        @{ Source = 'environment' }
        @{ Source = 'file' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Source = $Source } {
            param($Source)

            Mock Get-AvmLatestManagedFilesVersion { throw 'should not be called' }

            $settings = @{
                ManagedFilesRef       = 'feature-branch'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = $Source
                ManagedFilesVersionPin = $null
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'overridden'
            $plan.Ref | Should -Be 'feature-branch'
            $plan.ShouldStamp | Should -BeFalse
            $plan.Message | Should -BeNullOrEmpty
            Should -Invoke Get-AvmLatestManagedFilesVersion -Times 0
        }
    }

    It 'explains that upgrade has no effect when the ref is overridden' {
        InModuleScope 'Avm.Authoring' {
            $settings = @{
                ManagedFilesRef       = 'feature-branch'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'explicit'
                ManagedFilesVersionPin = $null
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git' -Upgrade

            $plan.Status | Should -Be 'overridden'
            $plan.Message | Should -Match 'has no effect'
        }
    }

    It 'adopts the latest version and stamps the pin when the repository is unpinned' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { [semver]'2.3.4' }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = $null
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'unpinned'
            $plan.Ref | Should -Be 'v2.3.4'
            $plan.TargetVersion.ToString() | Should -Be '2.3.4'
            $plan.ShouldStamp | Should -BeTrue
            $plan.Message | Should -BeNullOrEmpty
        }
    }

    It 'falls back to main and warns when unpinned and the lookup fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { throw [AvmManagedFilesLookupException]::new('offline') }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = $null
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'unpinned'
            $plan.Ref | Should -Be 'main'
            $plan.ShouldStamp | Should -BeFalse
            $plan.Message | Should -Match 'offline'
        }
    }

    It 'keeps the pinned ref and warns when the lookup fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { throw [AvmManagedFilesLookupException]::new('offline') }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'1.0.0' }
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'unknown'
            $plan.Ref | Should -Be 'v1.0.0'
            $plan.ShouldStamp | Should -BeFalse
            $plan.Message | Should -Match 'offline'
        }
    }

    It 'uses the pinned ref silently when up to date' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { [semver]'1.4.2' }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'1.4.2' }
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'upToDate'
            $plan.Ref | Should -Be 'v1.4.2'
            $plan.ShouldStamp | Should -BeFalse
            $plan.Message | Should -BeNullOrEmpty
        }
    }

    It 'stays on the pin and warns when a <ExpectedStatus> release is available' -TestCases @(
        @{ Latest = '1.4.3'; ExpectedStatus = 'patch' }
        @{ Latest = '1.5.0'; ExpectedStatus = 'minor' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Latest = $Latest; ExpectedStatus = $ExpectedStatus } {
            param($Latest, $ExpectedStatus)

            Mock Get-AvmLatestManagedFilesVersion { [semver]$Latest }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'1.4.2' }
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be $ExpectedStatus
            $plan.Ref | Should -Be 'v1.4.2'
            $plan.ShouldStamp | Should -BeFalse
            $plan.Message | Should -Match 'is available'
        }
    }

    It 'reports a major release as must-adopt without stamping' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { [semver]'2.0.0' }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'1.4.2' }
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git'

            $plan.Status | Should -Be 'major'
            $plan.Ref | Should -Be 'v1.4.2'
            $plan.ShouldStamp | Should -BeFalse
            $plan.Message | Should -Match 'major release'
        }
    }

    It 'moves to the latest version and stamps when upgrading to <Latest>' -TestCases @(
        @{ Latest = '1.4.3' }
        @{ Latest = '1.5.0' }
        @{ Latest = '2.0.0' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Latest = $Latest } {
            param($Latest)

            Mock Get-AvmLatestManagedFilesVersion { [semver]$Latest }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'1.4.2' }
            }
            $plan = Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git' -Upgrade

            $plan.Ref | Should -Be ('v{0}' -f $Latest)
            $plan.TargetVersion.ToString() | Should -Be $Latest
            $plan.ShouldStamp | Should -BeTrue
            $plan.Message | Should -BeNullOrEmpty
        }
    }

    It 'throws when upgrading and the latest version cannot be determined' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestManagedFilesVersion { throw [AvmManagedFilesLookupException]::new('offline') }

            $settings = @{
                ManagedFilesRef       = 'main'
                ManagedFilesRepo      = 'o/r'
                ManagedFilesRefSource = 'default'
                ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'1.4.2' }
            }

            { Resolve-AvmManagedFilesVersionPlan -Settings $settings -GitPath 'git' -Upgrade } |
                Should -Throw -ExceptionType ([AvmManagedFilesVersionException]) -PassThru |
                ForEach-Object { $_.Exception.Code | Should -Be 'AVM1060' }
        }
    }
}
