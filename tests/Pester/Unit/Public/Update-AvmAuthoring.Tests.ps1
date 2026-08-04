#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Set-StrictMode -Version 3.0

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    $script:manifestPath = Join-Path $script:moduleRoot 'Avm.Authoring.psd1'
    Import-Module $script:manifestPath -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Update-AvmAuthoring' {
    It 'is routed as avm update and bypasses the dispatcher stale-version gate' {
        InModuleScope 'Avm.Authoring' {
            Mock Test-AvmModuleVersion {
                throw [AvmModuleVersionException]::new(
                    [version]'1.0.0',
                    [version]'2.0.0',
                    'stale')
            }
            Mock Update-AvmAuthoring {
                [pscustomobject]@{
                    Name   = 'Avm.Authoring'
                    Status = 'current'
                    Marker = 'routed'
                }
            }

            $result = Invoke-Avm update --passthru

            $result.Marker | Should -Be 'routed'
            Should -Invoke Update-AvmAuthoring -Times 1 -Exactly
            Should -Invoke Test-AvmModuleVersion -Times 0 -Exactly
        }
    }

    It 'reports already current without invoking Update-PSResource' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [version]'1.0.0' }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Update-PSResource

            $result = Update-AvmAuthoring

            $result.Status | Should -Be 'current'
            $result.Message | Should -Match 'already current'
            Should -Invoke Update-PSResource -Times 0 -Exactly
        }
    }

    It 'invokes Update-PSResource with the required arguments when stale' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [version]'2.0.0' }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Update-PSResource

            $result = Update-AvmAuthoring -Confirm:$false

            $result.Status | Should -Be 'updated'
            $result.Message | Should -Match 'Start a new PowerShell session'
            $result.Message | Should -Match 'Import-Module Avm\.Authoring -Force'
            Should -Invoke Update-PSResource -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and
                $Scope -eq 'CurrentUser' -and
                $Repository -eq 'PSGallery' -and
                $Version -eq '2.0.0' -and
                $Confirm -eq $false -and
                $PassThru -eq $true -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'does not invoke Update-PSResource under WhatIf' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [version]'2.0.0' }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Update-PSResource

            $result = Update-AvmAuthoring -WhatIf

            $result.Status | Should -Be 'skipped'
            Should -Invoke Update-PSResource -Times 0 -Exactly
        }
    }

    It 'surfaces an actionable failure when Update-PSResource fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [version]'2.0.0' }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Update-PSResource {
                throw [System.InvalidOperationException]::new('gallery unavailable')
            }

            $caught = $null
            try {
                Update-AvmAuthoring -Confirm:$false
            }
            catch {
                $caught = $_.Exception
            }

            $caught | Should -BeOfType ([AvmToolException])
            $caught.Message | Should -Match 'Update-PSResource -Name Avm\.Authoring -Scope CurrentUser'
            $caught.Message | Should -Match 'gallery unavailable'
        }
    }
}
