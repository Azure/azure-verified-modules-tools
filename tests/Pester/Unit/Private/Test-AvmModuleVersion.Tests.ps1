#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Test-AvmModuleVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
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
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    value = @([pscustomobject]@{ Version = $current.ToString() })
                }
            }

            Test-AvmModuleVersion
            Test-AvmModuleVersion

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }

    It 'throws the dedicated exception and exit code when the module is outdated' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    value = @([pscustomobject]@{ Version = '99.0.0' })
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
            Mock Invoke-RestMethod { throw [System.Net.Http.HttpRequestException]::new('offline') }

            $warnings = Test-AvmModuleVersion -WarningVariable galleryWarnings 3>&1

            @($warnings).Count | Should -Be 1
            [string]$galleryWarnings | Should -Match 'Unable to check PowerShell Gallery'
        }
    }

    It 'warns and does not query when the check is skipped' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-RestMethod

            Test-AvmModuleVersion -SkipModuleVersionCheck -WarningVariable skipWarnings 3>$null

            [string]$skipWarnings | Should -Match 'version check was skipped'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }
}
