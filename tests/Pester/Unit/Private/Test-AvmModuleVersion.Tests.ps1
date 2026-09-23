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

    It 'queries PowerShell Gallery once and caches the result for direct cmdlets' {
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

    It 'refreshes the Gallery result for each top-level command' {
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
            { Invoke-Avm help | Out-Null } | Should -Throw -ExceptionType ([AvmModuleVersionException])

            Should -Invoke Find-PSResource -Times 2 -Exactly
        }
    }

    It 'rejects an outdated module with actionable guidance and a typed exit code' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '99.0.0' }
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
            $caught.CurrentVersion | Should -Be (Get-Module Avm.Authoring).Version
            $caught.LatestVersion | Should -Be ([version]'99.0.0')
            $caught.Message | Should -Match 'A newer version of Avm.Authoring is required'
            $caught.Message | Should -Match 'Update-PSResource -Name Avm\.Authoring -Scope CurrentUser'
            $caught.Message | Should -Match 'Import-Module Avm\.Authoring -Force'
        }
    }

    It 'warns instead of throwing for an outdated module in version-reporting mode' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '99.0.0' }
            }

            $records = @(Test-AvmModuleVersion -WarnOnly 3>&1)

            $records.Count | Should -Be 1
            $records[0] | Should -BeOfType ([System.Management.Automation.WarningRecord])
            [string]$records[0] | Should -Match 'update available: 99\.0\.0'
            [string]$records[0] | Should -Match 'avm update'
        }
    }

    It 'does not warn when the running module is current' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = $current.ToString() }
            }

            @(Test-AvmModuleVersion -WarnOnly 3>&1).Count | Should -Be 0
        }
    }

    It 'warns and continues when the PowerShell Gallery request fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                throw [System.Net.Http.HttpRequestException]::new('private diagnostic')
            }

            $warnings = @(Test-AvmModuleVersion 3>&1)

            $warnings.Count | Should -Be 1
            [string]$warnings[0] | Should -Match 'Unable to check PowerShell Gallery'
            [string]$warnings[0] | Should -Match 'The Gallery request failed'
            [string]$warnings[0] | Should -Not -Match 'private diagnostic'
        }
    }

    It 'describes <Kind> Gallery results without internal indexing errors' -TestCases @(
        @{ Kind = 'empty'; Expected = 'returned no Avm.Authoring package' }
        @{ Kind = 'wrong package'; Expected = 'did not return the requested Avm.Authoring package' }
        @{ Kind = 'missing version'; Expected = 'did not contain a version' }
        @{ Kind = 'invalid version'; Expected = 'returned an invalid Avm.Authoring version' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            ResultKind     = $Kind
            ExpectedDetail = $Expected
        } {
            $script:GalleryResultUnderTest = switch ($ResultKind) {
                'empty' { $null }
                'wrong package' { [pscustomobject]@{ Name = 'Another.Module'; Version = '1.0.0' } }
                'missing version' { [pscustomobject]@{ Name = 'Avm.Authoring' } }
                'invalid version' { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = 'not-a-version' } }
            }
            Mock Find-PSResource { $script:GalleryResultUnderTest }

            $warnings = @(Test-AvmModuleVersion 3>&1)

            [string]$warnings[0] | Should -Match $ExpectedDetail
            [string]$warnings[0] | Should -Not -Match 'Cannot index into a null array'
        }
    }

    It 'warns once and never queries the Gallery when the check is explicitly skipped' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource

            $warnings = @(
                Test-AvmModuleVersion -SkipModuleVersionCheck 3>&1
                Test-AvmModuleVersion -SkipModuleVersionCheck 3>&1
            )

            $warnings.Count | Should -Be 1
            [string]$warnings[0] | Should -Match 'version check was skipped'
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }

    It 'silently bypasses a nested check after the dispatcher already checked' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource

            $warnings = @(Test-AvmModuleVersion -SkipModuleVersionCheck -SuppressSkipWarning 3>&1)

            $warnings.Count | Should -Be 0
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }
}
