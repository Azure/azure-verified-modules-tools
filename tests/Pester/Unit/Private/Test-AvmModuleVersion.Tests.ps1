#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Test-AvmModuleVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        $script:originalTestSkip = $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK
        $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = '0'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
        if ($null -eq $script:originalTestSkip) {
            Remove-Item Env:AVM_TEST_SKIP_MODULE_VERSION_CHECK -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $script:originalTestSkip
        }
    }

    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:AvmLatestModuleVersion = $null
            $script:AvmModuleVersionCheckCompleted = $false
            $script:AvmModuleVersionSkipWarningWritten = $false
        }
    }

    It 'queries PowerShell Gallery and caches the latest version' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name    = 'Avm.Authoring'
                    Version = $current.ToString()
                }
            }

            Test-AvmModuleVersion
            Test-AvmModuleVersion

            Should -Invoke Find-PSResource -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and
                $Repository -eq 'PSGallery' -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'refreshes the Gallery result for sequential top-level avm invocations' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            $script:GalleryLookupCount = 0
            Mock Find-PSResource {
                $script:GalleryLookupCount++
                [pscustomobject]@{
                    Name    = 'Avm.Authoring'
                    Version = if ($script:GalleryLookupCount -eq 1) {
                        $current.ToString()
                    }
                    else {
                        '99.0.0'
                    }
                }
            }

            Invoke-Avm version | Out-Null

            $caught = $null
            try {
                Invoke-Avm version | Out-Null
            }
            catch {
                $caught = $_.Exception
            }

            Should -Invoke Find-PSResource -Times 2 -Exactly
            $caught | Should -BeOfType ([AvmModuleVersionException])
            $caught.Code | Should -Be 'AVM1050'
            $caught.CurrentVersion | Should -Be $current
            $caught.LatestVersion | Should -Be ([version]'99.0.0')
        }
    }

    It 'reports lookup, discovery, refresh, cache reuse, and comparison through verbose output' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name    = 'Avm.Authoring'
                    Version = $current.ToString()
                }
            }

            $first = Test-AvmModuleVersion -Verbose 4>&1
            $second = Test-AvmModuleVersion -Verbose 4>&1
            $dispatcher = Invoke-Avm version -Verbose 4>&1
            $messages = @(@($first) + @($second) + @($dispatcher) |
                    ForEach-Object { [string]$_ }) -join "`n"

            $messages | Should -Match 'module version lookup: querying PowerShell Gallery'
            $messages | Should -Match 'module version lookup: discovered latest PowerShell Gallery version'
            $messages | Should -Match 'module version lookup: reusing cached latest version'
            $messages | Should -Match 'module version lookup: refresh requested; discarding cached latest version'
            $messages | Should -Match 'module version check: comparing running version'
            Should -Invoke Find-PSResource -Times 2 -Exactly
        }
    }

    It 'throws the dedicated exception and exit code when the module is outdated' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name    = 'Avm.Authoring'
                    Version = '99.0.0'
                }
            }

            $caught = $null
            try {
                Test-AvmModuleVersion
            }
            catch {
                $caught = $_.Exception
            }

            $caught | Should -BeOfType ([AvmModuleVersionException])
            $caught.Code | Should -Be 'AVM1050'
            $caught.ExitCode | Should -Be 10
            $caught.Message | Should -Match 'Update-PSResource -Name Avm\.Authoring -Scope CurrentUser'
        }
    }

    It 'warns and continues when the PowerShell Gallery query fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource { throw [System.Net.Http.HttpRequestException]::new('offline') }

            $warnings = Test-AvmModuleVersion -WarningVariable galleryWarnings 3>&1

            @($warnings).Count | Should -Be 1
            [string]$galleryWarnings | Should -Match 'Unable to check PowerShell Gallery'
            [string]$galleryWarnings | Should -Match 'The Gallery request failed'
            [string]$galleryWarnings | Should -Not -Match 'offline'
        }
    }

    It 'reports a <Kind> Gallery result descriptively without runtime indexing errors' -TestCases @(
        @{
            Kind     = 'empty'
            Expected = 'returned no Avm.Authoring package'
        }
        @{
            Kind     = 'wrong package'
            Expected = 'did not return the requested Avm.Authoring package'
        }
        @{
            Kind     = 'missing version'
            Expected = 'did not contain a version'
        }
        @{
            Kind     = 'invalid version'
            Expected = 'Find-PSResource returned an invalid Avm.Authoring version'
        }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            ResultKind     = $Kind
            ExpectedDetail = $Expected
        } {
            $script:GalleryResultUnderTest = switch ($ResultKind) {
                'empty' { $null }
                'wrong package' {
                    [pscustomobject]@{ Name = 'Another.Module'; Version = '1.0.0' }
                }
                'missing version' {
                    [pscustomobject]@{ Name = 'Avm.Authoring' }
                }
                'invalid version' {
                    [pscustomobject]@{ Name = 'Avm.Authoring'; Version = 'not-a-version' }
                }
            }
            Mock Find-PSResource { $script:GalleryResultUnderTest }

            Test-AvmModuleVersion -WarningVariable galleryWarnings 3>$null

            [string]$galleryWarnings | Should -Match $ExpectedDetail
            [string]$galleryWarnings | Should -Not -Match 'Cannot index into a null array'
        }
    }

    It 'does not leak details from a <Kind> lookup failure into the warning' -TestCases @(
        @{ Kind = 'runtime'; Expected = 'lookup failed unexpectedly' }
        @{ Kind = 'http'; Expected = 'request failed' }
        @{ Kind = 'invalid data'; Expected = 'lookup failed unexpectedly' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            FailureKind   = $Kind
            ExpectedDetail = $Expected
        } {
            Mock Find-PSResource {
                $failure = switch ($FailureKind) {
                    'runtime' {
                        [System.Management.Automation.RuntimeException]::new(
                            'Cannot index into a null array.')
                    }
                    'http' {
                        [System.Net.Http.HttpRequestException]::new(
                            'Cannot index into a null array.')
                    }
                    'invalid data' {
                        [System.IO.InvalidDataException]::new(
                            'Cannot index into a null array.')
                    }
                }
                throw $failure
            }

            Test-AvmModuleVersion -WarningVariable galleryWarnings 3>$null

            [string]$galleryWarnings | Should -Match $ExpectedDetail
            [string]$galleryWarnings | Should -Not -Match 'Cannot index into a null array'
        }
    }

    It 'warns and does not query when the check is skipped' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource

            Test-AvmModuleVersion -SkipModuleVersionCheck -WarningVariable skipWarnings 3>$null

            [string]$skipWarnings | Should -Match 'version check was skipped'
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }

    It 'silently bypasses a nested check already performed by the dispatcher' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource

            Test-AvmModuleVersion `
                -SkipModuleVersionCheck `
                -SuppressSkipWarning `
                -WarningVariable skipWarnings `
                3>$null

            @($skipWarnings).Count | Should -Be 0
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }
}
