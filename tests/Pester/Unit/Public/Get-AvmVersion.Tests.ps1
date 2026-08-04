#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Get-AvmVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'returns a single pscustomobject' {
        $result = Get-AvmVersion
        $result | Should -BeOfType [pscustomobject]
        @($result).Count | Should -Be 1
    }

    It 'does not query or warn about PowerShell Gallery in ordinary public tests' {
        { [guid]$env:AVM_TEST_RUN_ID } | Should -Not -Throw
        $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK | Should -BeExactly $env:AVM_TEST_RUN_ID

        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                throw [System.InvalidOperationException]::new('must not query')
            }

            $result = Get-AvmVersion -WarningVariable versionWarnings 3>$null

            $result | Should -Not -BeNullOrEmpty
            @($versionWarnings).Count | Should -Be 0
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }

    It 'reports Module=Avm.Authoring (exact casing)' {
        (Get-AvmVersion).Module | Should -BeExactly 'Avm.Authoring'
    }

    It 'reports a non-empty Version' {
        (Get-AvmVersion).Version | Should -Not -BeNullOrEmpty
    }

    It 'handles the released 0.2.0 nested hashtable metadata shape' {
        InModuleScope 'Avm.Authoring' {
            $script:VersionModuleFixture = [pscustomobject]@{
                Name        = 'Avm.Authoring'
                Version     = [version]'0.2.0'
                PrivateData = @{
                    PSData = @{
                        Tags         = @('Azure', 'AVM')
                        ProjectUri   = 'https://github.com/Azure/azure-verified-modules-tools'
                        ReleaseNotes = 'Release notes'
                    }
                }
            }
            Mock Get-Module { $script:VersionModuleFixture }

            $result = Get-AvmVersion

            $result.Version | Should -BeExactly '0.2.0'
            $result.Prerelease | Should -BeNullOrEmpty
        }
    }

    It 'reads prerelease metadata from deserialized PSObject properties' {
        InModuleScope 'Avm.Authoring' {
            $script:VersionModuleFixture = [pscustomobject]@{
                Name        = 'Avm.Authoring'
                Version     = [version]'0.2.0'
                PrivateData = [pscustomobject]@{
                    PSData = [pscustomobject]@{
                        Prerelease = 'preview.4'
                    }
                }
            }
            Mock Get-Module { $script:VersionModuleFixture }

            $result = Get-AvmVersion

            $result.Version | Should -BeExactly '0.2.0'
            $result.Prerelease | Should -BeExactly 'preview.4'
        }
    }

    It 'reports the loaded module Version, not "unknown"' {
        $loaded = Get-Module -Name 'Avm.Authoring'
        (Get-AvmVersion).Version | Should -Be $loaded.Version.ToString()
    }

    It 'reports OS in the allowed set' {
        (Get-AvmVersion).OS | Should -BeIn @('windows', 'linux', 'macos')
    }

    It 'reports PSEdition=Core' {
        (Get-AvmVersion).PSEdition | Should -Be 'Core'
    }

    It 'reports a non-empty Architecture' {
        (Get-AvmVersion).Architecture | Should -Not -BeNullOrEmpty
    }

    It 'PSVersion parses as a System.Version' {
        # F47: `[version]$null` does not throw, so -Not -Throw alone passes when
        # PSVersion is missing entirely. Pin the value before casting it.
        $psVersion = (Get-AvmVersion).PSVersion
        $psVersion | Should -Not -BeNullOrEmpty
        { [version]$psVersion } | Should -Not -Throw
        ([version]$psVersion).Major | Should -BeGreaterOrEqual 7
    }
}

Describe 'avm version (dispatcher)' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'routes "avm version" to Get-AvmVersion' {
        $direct = Get-AvmVersion
        $via = avm version
        $via.Module | Should -BeExactly $direct.Module
        $via.Version | Should -Be $direct.Version
    }

    It 'queries and warns only once when the dispatcher Gallery lookup fails' {
        InModuleScope 'Avm.Authoring' {
            $previousTestSkip = $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK
            $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = '0'
            try {
                $script:AvmLatestModuleVersion = $null
                $script:AvmModuleVersionCheckCompleted = $false
                $script:AvmModuleVersionSkipWarningWritten = $false
                Mock Find-PSResource {
                    throw [System.Net.Http.HttpRequestException]::new('offline')
                }

                $records = @(Invoke-Avm version 3>&1)
                $warnings = @($records | Where-Object {
                        $_ -is [System.Management.Automation.WarningRecord]
                    })
                $result = @($records | Where-Object {
                        $_ -isnot [System.Management.Automation.WarningRecord]
                    })

                $warnings.Count | Should -Be 1
                [string]$warnings[0] | Should -Match 'The Gallery request failed'
                [string]$warnings[0] | Should -Not -Match 'Cannot index into a null array'
                $result.Count | Should -Be 1
                $result[0].Module | Should -BeExactly 'Avm.Authoring'
                Should -Invoke Find-PSResource -Times 1 -Exactly
            }
            finally {
                $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $previousTestSkip
            }
        }
    }

    It 'emits only the explicit skip warning through the dispatcher' {
        InModuleScope 'Avm.Authoring' {
            $previousTestSkip = $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK
            $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = '0'
            try {
                $script:AvmModuleVersionSkipWarningWritten = $false
                Mock Find-PSResource

                $records = @(Invoke-Avm -SkipModuleVersionCheck version 3>&1)
                $warnings = @($records | Where-Object {
                        $_ -is [System.Management.Automation.WarningRecord]
                    })

                $warnings.Count | Should -Be 1
                [string]$warnings[0] | Should -Match 'version check was skipped'
                Should -Invoke Find-PSResource -Times 0 -Exactly
            }
            finally {
                $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $previousTestSkip
            }
        }
    }

    It 'errors on an unknown verb' {
        { avm nope } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'with no arguments, prints help and returns nothing' {
        # Help is emitted via Write-Information; the return value is $null.
        $result = avm 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'lists the tool verbs in the help text' {
        $info = avm 6>&1 | Out-String
        $info | Should -Match 'tool list'
        $info | Should -Match 'tool which'
        $info | Should -Match 'tool install'
    }
}
