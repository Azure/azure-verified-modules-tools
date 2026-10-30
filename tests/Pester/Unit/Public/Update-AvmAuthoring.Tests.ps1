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
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            $script:AvmLatestModuleVersion = $null
            $script:AvmLatestModuleRelease = $null
            $script:AvmModuleVersionCheckCompleted = $false
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'UserFeed'; Priority = 10 } }
            Mock Get-InstalledPSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = [version]'2.0.0' } }
        }
    }
    It 'is routed as avm upgrade and bypasses the stale-version gate' {
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

            $result = Invoke-Avm upgrade --passthru

            $result.Marker | Should -Be 'routed'
            Should -Invoke Update-AvmAuthoring -Times 1 -Exactly
            Should -Invoke Test-AvmModuleVersion -Times 0 -Exactly
        }
    }

    It 'rejects avm update without invoking the self-update command' {
        InModuleScope 'Avm.Authoring' {
            Mock Test-AvmModuleVersion
            Mock Update-AvmAuthoring

            { Invoke-Avm update } | Should -Throw "*Unknown verb: 'update'*"

            Should -Invoke Update-AvmAuthoring -Times 0 -Exactly
            Should -Invoke Test-AvmModuleVersion -Times 1 -Exactly
        }
    }

    It 'reports already current without invoking Update-PSResource' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'1.0.0'; Repositories = @('UserFeed') } }
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
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('UserFeed') } }
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
                $Repository -eq 'UserFeed' -and
                $Version -eq '2.0.0' -and
                $Confirm -eq $false -and
                $PassThru -eq $true -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'does not invoke Update-PSResource under WhatIf' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('UserFeed') } }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Update-PSResource

            $result = Update-AvmAuthoring -WhatIf

            $result.Status | Should -Be 'skipped'
            Should -Invoke Update-PSResource -Times 0 -Exactly
        }
    }

    It 'updates the selected exact version from the next configured repository after failure' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('Preferred', 'Backup') } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'Backup'; Priority = 20 }
                [pscustomobject]@{ Name = 'Preferred'; Priority = 10 }
            }
            $script:repositoryAttemptOrder = [Collections.Generic.List[string]]::new()
            $updateStateUnderTest = @{ Installed = $false }
            Mock Get-InstalledPSResource {
                if ($updateStateUnderTest.Installed) { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = [version]'2.0.0' } }
            }
            Mock Update-PSResource {
                $script:repositoryAttemptOrder.Add($Repository)
                if ($Repository -eq 'Preferred') { throw [InvalidOperationException]::new('Package not found') }
                $updateStateUnderTest.Installed = $true
            }

            (Update-AvmAuthoring -Confirm:$false).Status | Should -Be 'updated'
            $script:repositoryAttemptOrder.ToArray() | Should -Be @('Preferred', 'Backup')
            Should -Invoke Update-PSResource -Exactly 2 -ParameterFilter { $Version -eq '2.0.0' }
        }
    }

    It 'upgrades from the repository with the highest version without special MAR ordering' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('OfficialPackages') } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'CompanyFeed'; Priority = 1; Uri = 'https://packages.example.test/' }
                [pscustomobject]@{ Name = 'OfficialPackages'; Priority = 99; Uri = 'https://mcr.microsoft.com/' }
            }
            Mock Update-PSResource

            $result = Update-AvmAuthoring -Confirm:$false

            $result.Name | Should -Be 'Avm.Authoring'
            $result.Status | Should -Be 'updated'
            Should -Invoke Update-PSResource -Exactly 1 -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and $Repository -eq 'OfficialPackages' -and $Version -eq '2.0.0'
            }
            Should -Invoke Update-PSResource -Exactly 0 -ParameterFilter { $Repository -eq 'CompanyFeed' }
            Should -Invoke Get-InstalledPSResource -Exactly 1 -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and $Version -eq '2.0.0' -and $Scope -eq 'CurrentUser'
            }
            Should -Invoke Get-AvmLatestModuleVersion -Exactly 1 -ParameterFilter { $IncludeRepository }
        }
    }

    It 'falls back between latest-version sources without changing the selected version after <Failure>' -ForEach @(
        @{ Failure = 'package failure' }
        @{ Failure = 'no installed update' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Failure = $Failure } {
            param($Failure)
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('CompanyFeed', 'OfficialPackages') } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'CompanyFeed'; Priority = 1; Uri = 'https://packages.example.test/' }
                [pscustomobject]@{ Name = 'OfficialPackages'; Priority = 99; Uri = 'https://mcr.microsoft.com/' }
            }
            $calls = [Collections.Generic.List[string]]::new()
            $state = @{ Installed = $false }
            Mock Get-InstalledPSResource {
                if ($state.Installed) { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = [version]'2.0.0' } }
            }
            Mock Update-PSResource {
                $calls.Add($Repository)
                if ($Repository -eq 'CompanyFeed' -and $Failure -eq 'package failure') {
                    throw [InvalidOperationException]::new('Not published')
                }
                $state.Installed = $Repository -eq 'OfficialPackages'
            }

            (Update-AvmAuthoring -Confirm:$false).Status | Should -Be 'updated'
            $calls.ToArray() | Should -Be @('CompanyFeed', 'OfficialPackages')
            Should -Invoke Update-PSResource -Exactly 2 -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and $Version -eq '2.0.0'
            }
        }
    }

    It 'discovers all feeds and upgrades the latest release from <Expected>' -ForEach @(
        @{ CompanyVersion = '2.9.0'; RegistryVersion = '2.10.0'; Expected = 'OfficialPackages'; Latest = '2.10.0' }
        @{ CompanyVersion = '2.10.0'; RegistryVersion = '2.9.0'; Expected = 'CompanyFeed'; Latest = '2.10.0' }
        @{ CompanyVersion = '2.10.0'; RegistryVersion = '2.10.0'; Expected = 'CompanyFeed'; Latest = '2.10.0' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            CompanyVersion = $CompanyVersion; RegistryVersion = $RegistryVersion; Expected = $Expected; Latest = $Latest
        } {
            param($CompanyVersion, $RegistryVersion, $Expected, $Latest)
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'OfficialPackages'; Priority = 99; Uri = 'https://mcr.microsoft.com/' }
                [pscustomobject]@{ Name = 'CompanyFeed'; Priority = 1; Uri = 'https://packages.example.test/' }
            }
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name = 'Avm.Authoring'
                    Version = if ($Repository -eq 'CompanyFeed') { $CompanyVersion } else { $RegistryVersion }
                }
            }
            Mock Update-PSResource
            Mock Get-InstalledPSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = [version]$Latest } }

            $result = Update-AvmAuthoring -Confirm:$false

            $result.Status | Should -Be 'updated'
            $result.LatestVersion | Should -Be ([version]$Latest)
            Should -Invoke Find-PSResource -Exactly 2
            Should -Invoke Update-PSResource -Exactly 1
            Should -Invoke Update-PSResource -Exactly 1 -ParameterFilter {
                $Repository -eq $Expected -and $Version -eq $Latest -and $Name -eq 'Avm.Authoring'
            }
        }
    }

    It 'does not downgrade when every source of the latest version fails to install' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'OlderFeed'; Priority = 1 }
                [pscustomobject]@{ Name = 'LatestFeed'; Priority = 2 }
            }
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = if ($Repository -eq 'OlderFeed') { '2.0.0' } else { '3.0.0' } }
            }
            Mock Update-PSResource { throw [InvalidOperationException]::new('Install failed') }

            { Update-AvmAuthoring -Confirm:$false } | Should -Throw '*Failed to update Avm.Authoring from 1.0.0 to 3.0.0*'
            Should -Invoke Update-PSResource -Exactly 1 -ParameterFilter { $Repository -eq 'LatestFeed' -and $Version -eq '3.0.0' }
            Should -Invoke Update-PSResource -Exactly 0 -ParameterFilter { $Repository -eq 'OlderFeed' }
        }
    }

    It 'surfaces an actionable failure when Update-PSResource fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('UserFeed') } }
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

    It 'does not reinstall when a transient failure hid a completed update' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('UserFeed') } }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Wait-AvmRetryDelay
            Mock Write-Warning
            Mock Update-PSResource { throw [System.Net.Http.HttpRequestException]::new('The operation has timed out.') }
            Mock Get-InstalledPSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' } }

            (Update-AvmAuthoring -Confirm:$false).Status | Should -Be 'updated'

            Should -Invoke Update-PSResource -Exactly 1
            Should -Invoke Get-InstalledPSResource -Exactly 1 -ParameterFilter { $Version -eq '2.0.0' }
        }
    }

    It 'retries a transient update failure when the new version is not installed' {
        InModuleScope 'Avm.Authoring' {
            $state = @{ Calls = 0 }
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('UserFeed') } }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0' }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Wait-AvmRetryDelay
            Mock Write-Warning
            Mock Update-PSResource {
                $state.Calls++
                if ($state.Calls -eq 1) { throw [System.Net.Http.HttpRequestException]::new('Connection reset by peer') }
            }
            Mock Get-InstalledPSResource {
                if ($state.Calls -gt 1) { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = [version]'2.0.0' } }
            }

            (Update-AvmAuthoring -Confirm:$false).Status | Should -Be 'updated'

            Should -Invoke Update-PSResource -Exactly 2
        }
    }

    It 'falls through when an update returns without installing the selected version' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmLatestModuleVersion { [pscustomobject]@{ Version = [version]'2.0.0'; Repositories = @('Preferred', 'Backup') } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'Preferred'; Priority = 10 }
                [pscustomobject]@{ Name = 'Backup'; Priority = 20 }
            }
            $updateStateUnderTest = @{ Installed = $false }
            Mock Get-InstalledPSResource {
                if ($updateStateUnderTest.Installed) { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = [version]'2.0.0' } }
            }
            Mock Update-PSResource { $updateStateUnderTest.Installed = $Repository -eq 'Backup' }

            (Update-AvmAuthoring -Confirm:$false).Status | Should -Be 'updated'
            Should -Invoke Update-PSResource -Exactly 1 -ParameterFilter { $Repository -eq 'Backup' }
        }
    }
}
