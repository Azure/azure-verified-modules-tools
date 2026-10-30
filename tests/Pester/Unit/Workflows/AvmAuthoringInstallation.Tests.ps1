#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:installer = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'actions' 'install-avm-authoring' 'Install-AvmAuthoring.ps1'

    function Install-Module {
        [CmdletBinding()]
        param([string] $Name, [version] $MinimumVersion, [string] $Scope, [switch] $Force, [switch] $AllowClobber)
        throw 'Install-Module must be mocked.'
    }

    function Install-PSResource {
        [CmdletBinding()]
        param([string] $Name, [string] $Version, [string] $Repository, [string] $Scope, [switch] $TrustRepository)
        throw 'Install-PSResource must be mocked.'
    }

    function Save-PSResource {
        [CmdletBinding()]
        param([string] $Name, [string] $Version, [string] $Repository, [string] $Path, [switch] $TrustRepository)
        throw 'Save-PSResource must be mocked.'
    }

    function Get-PSResourceRepository {
        [CmdletBinding()]
        param()
        throw 'Get-PSResourceRepository must be mocked.'
    }

    function Register-PSResourceRepository {
        [CmdletBinding()]
        param([string] $Name, [string] $Uri, [string] $ApiVersion, [switch] $Trusted)
        throw 'Register-PSResourceRepository must be mocked.'
    }

    function Find-PSResource {
        [CmdletBinding()]
        param([string] $Name, [string] $Repository, [string] $Version)
        throw 'Find-PSResource must be mocked.'
    }
}

Describe 'Shared Avm.Authoring workflow installer' {
    BeforeEach {
        $global:AvmAuthoringInstallAttempts = [Collections.Generic.List[string]]::new()
        $global:AvmAuthoringFindAttempts = [Collections.Generic.List[string]]::new()
        $global:AvmAuthoringBootstrapAttempts = 0
        Mock Get-Module {
            [pscustomobject]@{ Name = 'Microsoft.PowerShell.PSResourceGet'; Version = [version]'1.1.1' }
        } -ParameterFilter { $ListAvailable -and $Name -eq 'Microsoft.PowerShell.PSResourceGet' }
        Mock Import-Module {}
        Mock Install-Module {}
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'UserFeed'; Priority = 10; Uri = 'https://example.invalid/gallery' }
        }
        Mock Register-PSResourceRepository {}
        Mock Find-PSResource {
            $global:AvmAuthoringFindAttempts.Add($Repository)
            [pscustomobject]@{ Version = [version]'2.0.0' }
        }
        Mock Install-PSResource { $global:AvmAuthoringInstallAttempts.Add("$Repository/$Version") }
        Mock Save-PSResource { $global:AvmAuthoringInstallAttempts.Add("$Repository/$Version") }
        Mock Start-Sleep {}
        Mock Write-Warning {}
    }

    It 'registers MAR once when its endpoint is absent' {
        & $script:installer | Should -Not -BeNullOrEmpty

        Should -Invoke Register-PSResourceRepository -Exactly 1 -ParameterFilter {
            $Name -eq 'MAR' -and $Uri -eq 'https://mcr.microsoft.com/' -and
            $ApiVersion -eq 'ContainerRegistry' -and $Trusted
        }
    }

    It 'preserves an existing MAR registration under an arbitrary name' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'CorporateArtifactRegistry'; Priority = 10; Uri = 'https://mcr.microsoft.com/' }
            [pscustomobject]@{ Name = 'UserFeed'; Priority = 20; Uri = 'https://example.invalid/gallery' }
        }

        & $script:installer | Should -Not -BeNullOrEmpty

        Should -Invoke Register-PSResourceRepository -Exactly 0
    }

    It 'selects the newest stable release across all configured repositories' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'Preferred'; Priority = 10; Uri = 'https://example.invalid/preferred' }
            [pscustomobject]@{ Name = 'Newest'; Priority = 20; Uri = 'https://example.invalid/newest' }
        }
        Mock Find-PSResource {
            $global:AvmAuthoringFindAttempts.Add($Repository)
            if ($Repository -eq 'Preferred') { [pscustomobject]@{ Version = [version]'1.0.0' } }
            if ($Repository -eq 'Newest') { [pscustomobject]@{ Version = [version]'2.0.0' } }
        }

        (& $script:installer).Version | Should -Be ([version]'2.0.0')
        $global:AvmAuthoringInstallAttempts.ToArray() | Should -Be @('Newest/2.0.0')
    }

    It 'falls back when MAR does not contain Avm.Authoring' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'MAR'; Priority = 10; Uri = 'https://mcr.microsoft.com/' }
            [pscustomobject]@{ Name = 'UserFeed'; Priority = 20; Uri = 'https://example.invalid/gallery' }
        }
        Mock Find-PSResource {
            $global:AvmAuthoringFindAttempts.Add($Repository)
            if ($Repository -eq 'UserFeed') { [pscustomobject]@{ Version = [version]'2.0.0' } }
        }

        (& $script:installer).Repository | Should -Be 'UserFeed'
        $global:AvmAuthoringInstallAttempts.ToArray() | Should -Be @('UserFeed/2.0.0')
    }

    It 'uses configured priority and name order when feeds publish the same newest release' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'Zulu'; Priority = 10; Uri = 'https://example.invalid/zulu' }
            [pscustomobject]@{ Name = 'Alpha'; Priority = 10; Uri = 'https://example.invalid/alpha' }
        }

        (& $script:installer).Repository | Should -Be 'Alpha'
        $global:AvmAuthoringInstallAttempts.ToArray() | Should -Be @('Alpha/2.0.0')
    }

    It 'falls back only to a source serving the selected version' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'Preferred'; Priority = 10; Uri = 'https://example.invalid/preferred' }
            [pscustomobject]@{ Name = 'Older'; Priority = 20; Uri = 'https://example.invalid/older' }
            [pscustomobject]@{ Name = 'Backup'; Priority = 30; Uri = 'https://example.invalid/backup' }
        }
        Mock Find-PSResource {
            if ($Repository -eq 'Older') { [pscustomobject]@{ Version = [version]'1.0.0' } }
            else { [pscustomobject]@{ Version = [version]'2.0.0' } }
        }
        Mock Install-PSResource {
            $global:AvmAuthoringInstallAttempts.Add("$Repository/$Version")
            if ($Repository -eq 'Preferred') { throw 'Package unavailable.' }
        }

        (& $script:installer).Repository | Should -Be 'Backup'
        $global:AvmAuthoringInstallAttempts.ToArray() | Should -Be @(
            'Preferred/2.0.0', 'Preferred/2.0.0', 'Preferred/2.0.0', 'Backup/2.0.0'
        )
    }

    It 'surfaces an installation failure after the shared retry budget is exhausted' {
        Mock Install-PSResource { throw 'Synthetic PowerShell Gallery HTTP 403 (Forbidden)' }

        { & $script:installer } | Should -Throw '*PowerShell Gallery HTTP 403 (Forbidden)*'

        Should -Invoke Install-PSResource -Exactly 3
        Should -Invoke Start-Sleep -Exactly 2
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 10 }
    }

    It 'stops exact-version discovery and installation at the first successful source' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'Preferred'; Priority = 10; Uri = 'https://example.invalid/preferred' }
            [pscustomobject]@{ Name = 'Backup'; Priority = 20; Uri = 'https://example.invalid/backup' }
        }
        Mock Find-PSResource {
            $global:AvmAuthoringFindAttempts.Add($Repository)
            [pscustomobject]@{ Version = [version]'1.2.3' }
        }

        (& $script:installer -Version 1.2.3).Repository | Should -Be 'Preferred'
        $global:AvmAuthoringFindAttempts.ToArray() | Should -Be @('Preferred')
        $global:AvmAuthoringInstallAttempts.ToArray() | Should -Be @('Preferred/1.2.3')
    }

    It 'uses a Gallery version constraint while selecting the concrete release' {
        Mock Find-PSResource {
            $global:AvmAuthoringFindAttempts.Add($Repository)
            [pscustomobject]@{ Version = [version]'1.2.3' }
        }

        (& $script:installer -VersionConstraint '[1.0.0,2.0.0)').Version | Should -Be ([version]'1.2.3')

        Should -Invoke Find-PSResource -Exactly 1 -ParameterFilter {
            $Repository -eq 'UserFeed' -and $Version -eq '[1.0.0,2.0.0)'
        }
        $global:AvmAuthoringInstallAttempts.ToArray() | Should -Be @('UserFeed/1.2.3')
    }

    It 'retries PSResourceGet bootstrap failures before installing' {
        Mock Get-Module {} -ParameterFilter { $ListAvailable -and $Name -eq 'Microsoft.PowerShell.PSResourceGet' }
        Mock Install-Module {
            $global:AvmAuthoringBootstrapAttempts++
            if ($global:AvmAuthoringBootstrapAttempts -eq 1) { throw 'Package manager unavailable.' }
        }

        & $script:installer | Should -Not -BeNullOrEmpty

        Should -Invoke Install-Module -Exactly 2 -ParameterFilter {
            $Name -eq 'Microsoft.PowerShell.PSResourceGet' -and $MinimumVersion -eq [version]'1.1.1' -and
            $Scope -eq 'CurrentUser' -and $Force -and $AllowClobber
        }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 5 }
    }

    It 'saves the selected package for the signed bootstrap artifact' {
        $destination = Join-Path $TestDrive 'package'

        (& $script:installer -Operation Save -DestinationPath $destination).DestinationPath | Should -Be $destination

        Should -Invoke Save-PSResource -Exactly 1 -ParameterFilter {
            $Name -eq 'Avm.Authoring' -and $Version -eq '2.0.0' -and $Repository -eq 'UserFeed' -and
            $Path -eq $destination -and $TrustRepository
        }
        Should -Invoke Install-PSResource -Exactly 0
    }
}
