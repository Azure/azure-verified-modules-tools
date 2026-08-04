function Get-AvmVersion {
    <#
    .SYNOPSIS
        Reports the running Avm.Authoring module version and host runtime.

    .DESCRIPTION
        Emits a single pscustomobject covering the module identity, the running
        PowerShell version and edition, the detected OS, and the process
        architecture. Used by `avm version` and by the test harness to confirm
        that the module under test is the one on disk.

    .EXAMPLE
        PS> Get-AvmVersion
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $module = Get-Module -Name 'Avm.Authoring' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $module) {
        $module = Get-Module -Name 'Avm.Authoring' -ListAvailable |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }

    $privateData = Get-AvmPropertyValue -InputObject $module -Name 'PrivateData'
    $psData = Get-AvmPropertyValue -InputObject $privateData -Name 'PSData'
    $prerelease = [string](Get-AvmPropertyValue -InputObject $psData -Name 'Prerelease')
    if ([string]::IsNullOrWhiteSpace($prerelease)) {
        $prerelease = $null
    }

    $os = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'unknown' }
    $moduleVersion = Get-AvmPropertyValue -InputObject $module -Name 'Version'

    [pscustomobject][ordered]@{
        Module       = 'Avm.Authoring'
        Version      = if ($null -ne $moduleVersion) { $moduleVersion.ToString() } else { 'unknown' }
        Prerelease   = $prerelease
        PSVersion    = $PSVersionTable.PSVersion.ToString()
        PSEdition    = [string]$PSVersionTable.PSEdition
        OS           = $os
        Architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    }
}
