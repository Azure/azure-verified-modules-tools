#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' '..' '..' 'scripts' 'bicep-workflows' 'Common.ps1')
    function Install-PSResource {
        [CmdletBinding()]
        param([string] $Name, [string] $Version, [string] $Repository, [string] $Scope, [switch] $TrustRepository, [switch] $Quiet)
        throw 'Installation must be mocked.'
    }

    function Get-PSResourceRepository {
        [CmdletBinding()]
        param([string] $Name)
        throw 'Repository lookup must be mocked.'
    }
    function Install-AvmTool {
        [CmdletBinding()]
        param([string] $Name, [switch] $SkipModuleVersionCheck)
        throw 'Tool installation must be mocked.'
    }
}

Describe 'Bicep workflow bounded Git reads' {
    BeforeEach {
        Mock Invoke-AvmWorkflowProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = 'fixture'; StdErr = '' }
        }
        Mock Start-Sleep {}
    }

    It 'does not retry a successful read' {
        (Invoke-AvmWorkflowGitRead -Root $TestDrive -Arguments @('ls-remote', '--tags', 'origin') -Remote).StdOut | Should -BeExactly 'fixture'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 1
        Should -Invoke Start-Sleep -Exactly 0
    }

    It 'bounds a failed remote read to three attempts and retains the failure' {
        Mock Invoke-AvmWorkflowProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fixture unavailable' } }
        { Invoke-AvmWorkflowGitRead -Root $TestDrive -Arguments @('ls-remote', '--tags', 'origin') -Remote } | Should -Throw '*3 attempt*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 3
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 4 }
    }

    It 'bounds remote timeouts without returning a successful-looking empty result' {
        Mock Invoke-AvmWorkflowProcess { throw [TimeoutException]::new('fixture timeout') }
        { Invoke-AvmWorkflowGitRead -Root $TestDrive -Arguments @('ls-remote', '--tags', 'origin') -Remote -AllowFailure } |
            Should -Throw '*timeout*'
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 3
    }

    It 'does not repeat an expected missing local commit lookup' {
        Mock Invoke-AvmWorkflowProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'missing' } }
        (Invoke-AvmWorkflowGitRead -Root $TestDrive -Arguments @('cat-file', '-e', ('a' * 40)) -AllowFailure).ExitCode | Should -Be 1
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 1
    }
}

Describe 'Bicep workflow packaged-compliance qualification' {
    BeforeEach {
        $script:capability = 1
        Mock Install-AvmWorkflowModule {}
        Mock Import-AvmWorkflowPackage {}
        Mock Install-AvmTool {}
        Mock Write-AvmWorkflowOutput {}
        Mock Get-Module { Microsoft.PowerShell.Core\Get-Module @PesterBoundParameters }
        Mock Get-Module {
            [pscustomobject]@{
                Version = [version]'1.2.3'
                PrivateData = @{ AvmCapabilities = @{ BicepPackagedCompliance = $script:capability } }
            }
        } -ParameterFilter { $Name -eq 'Avm.Authoring' }
    }

    It 'requires the qualified manifest marker before preparing the Static route' {
        Initialize-AvmWorkflow -Version 1.2.3 -Profile Static -Confirm:$false
        Should -Invoke Install-AvmWorkflowModule -Exactly 1 -ParameterFilter { $Name -eq 'Avm.Authoring' -and $Version -eq [version]'1.2.3' }
        Should -Invoke Install-AvmWorkflowModule -Exactly 1 -ParameterFilter { $Name -eq 'Pester' }
        Should -Invoke Install-AvmTool -Exactly 1 -ParameterFilter { $Name -eq 'bicep' -and $SkipModuleVersionCheck }
        Should -Invoke Write-AvmWorkflowOutput -Exactly 1 -ParameterFilter { $Name -eq 'AVM_AUTHORING_VERSION' -and $Value -ceq '1.2.3' }
    }

    It 'rejects missing, unsupported or nonnumeric capability values (<Label>)' -ForEach @(
        @{ Label = 'missing'; Value = $null }
        @{ Label = 'zero'; Value = 0 }
        @{ Label = 'unsupported'; Value = 2 }
        @{ Label = 'string'; Value = '1' }
    ) {
        $script:capability = $Value
        { Initialize-AvmWorkflow -Version 1.2.3 -Profile Static -Confirm:$false } | Should -Throw '*BicepPackagedCompliance capability 1*'
        Should -Invoke Install-AvmWorkflowModule -Exactly 0 -ParameterFilter { $Name -ne 'Avm.Authoring' }
        Should -Invoke Install-AvmTool -Exactly 0
        Should -Invoke Write-AvmWorkflowOutput -Exactly 0
    }

    It 'does not infer readiness from the presence of a compiled-check file or another loaded version' {
        Mock Get-Module {
            [pscustomobject]@{ Version = [version]'9.9.9'; PrivateData = @{ AvmCapabilities = @{ BicepPackagedCompliance = 1 } } }
        } -ParameterFilter { $Name -eq 'Avm.Authoring' }
        { Initialize-AvmWorkflow -Version 1.2.3 -Profile Static -Confirm:$false } | Should -Throw '*BicepPackagedCompliance capability 1*'
        Should -Invoke Install-AvmTool -Exactly 0
    }
}

Describe 'Bicep workflow exact-version installation' {
    BeforeEach {
        $script:installedVersion = $null
        Mock Get-Module { Microsoft.PowerShell.Core\Get-Module @PesterBoundParameters }
        Mock Get-Module {
            if ($null -ne $script:installedVersion) {
                [pscustomobject]@{ Name = 'FixturePackage'; Version = $script:installedVersion }
            }
        } -ParameterFilter { $Name -eq 'FixturePackage' -and $ListAvailable }
        Mock Import-Module {}
        Mock Get-PSResourceRepository { [pscustomobject]@{ Uri = 'https://www.powershellgallery.com/api/v2' } }
        Mock Install-PSResource { $script:installedVersion = [version]$Version }
        Mock Start-Sleep {}
    }

    It 'reuses the exact installed package without network access' {
        $script:installedVersion = [version]'1.2.3'
        (Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Confirm:$false).Version | Should -Be ([version]'1.2.3')
        Should -Invoke Install-PSResource -Exactly 0
        Should -Invoke Get-PSResourceRepository -Exactly 0
    }

    It 'does not silently accept a different installed authoring version' {
        $script:installedVersion = [version]'2.0.0'
        (Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Confirm:$false).Version | Should -Be ([version]'1.2.3')
        Should -Invoke Install-PSResource -Exactly 1 -ParameterFilter { $Version -eq '1.2.3' }
    }

    It 'reuses an installed dependency that satisfies an explicit minimum' {
        $script:installedVersion = [version]'2.0.0'
        (Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Minimum -Confirm:$false).Version | Should -Be ([version]'2.0.0')
        Should -Invoke Install-PSResource -Exactly 0
    }

    It 'reconciles a completed installation after a transient response error before retrying' {
        Mock Install-PSResource {
            $script:installedVersion = [version]$Version
            throw [Net.Http.HttpRequestException]::new('HTTP 504')
        }
        (Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Confirm:$false).Version | Should -Be ([version]'1.2.3')
        Should -Invoke Install-PSResource -Exactly 1
    }

    It 'bounds transient failures to three attempts and exponential waits' {
        Mock Install-PSResource { throw [Net.Http.HttpRequestException]::new('HTTP 503') }
        { Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Confirm:$false } | Should -Throw '*503*'
        Should -Invoke Install-PSResource -Exactly 3
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 10 }
    }

    It 'does not replay a permanent installation failure' {
        Mock Install-PSResource { throw [InvalidOperationException]::new('Package version does not exist.') }
        { Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Confirm:$false } | Should -Throw '*does not exist*'
        Should -Invoke Install-PSResource -Exactly 1
        Should -Invoke Start-Sleep -Exactly 0
    }

    It 'rejects an overridden gallery endpoint' {
        Mock Get-PSResourceRepository { [pscustomobject]@{ Uri = 'https://example.invalid/gallery' } }
        { Install-AvmWorkflowModule -Name FixturePackage -Version 1.2.3 -Confirm:$false } | Should -Throw '*official HTTPS*'
        Should -Invoke Install-PSResource -Exactly 0
    }

    It 'refuses missing, development or floating release values (<Value>)' -ForEach @(
        @{ Value = '' }
        @{ Value = '0.0.0' }
        @{ Value = 'latest' }
        @{ Value = '[1.2.3,2.0.0)' }
    ) {
        { Initialize-AvmWorkflow -Version $Value -Profile Static -Confirm:$false } | Should -Throw '*exact qualified release*'
        Should -Invoke Install-PSResource -Exactly 0
    }
}
