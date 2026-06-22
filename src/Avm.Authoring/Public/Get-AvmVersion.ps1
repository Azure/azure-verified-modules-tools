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
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $module = Get-Module -Name 'Avm.Authoring'
    if (-not $module) {
        $module = Get-Module -Name 'Avm.Authoring' -ListAvailable |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }

    $prerelease = $null
    if ($module -and $module.PrivateData -and
        $module.PrivateData.ContainsKey('PSData') -and
        $module.PrivateData['PSData'].ContainsKey('Prerelease')) {
        $prerelease = [string]$module.PrivateData['PSData']['Prerelease']
        if ([string]::IsNullOrWhiteSpace($prerelease)) { $prerelease = $null }
    }

    $os = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'unknown' }

    [pscustomobject][ordered]@{
        Module       = 'Avm.Authoring'
        Version      = if ($module) { $module.Version.ToString() } else { 'unknown' }
        Prerelease   = $prerelease
        PSVersion    = $PSVersionTable.PSVersion.ToString()
        PSEdition    = [string]$PSVersionTable.PSEdition
        OS           = $os
        Architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    }
}
