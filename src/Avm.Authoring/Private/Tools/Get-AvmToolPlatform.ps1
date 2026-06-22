function Get-AvmToolPlatform {
    <#
    .SYNOPSIS
        Return the current OS/arch as a 'windows-amd64' style platform tag.

    .DESCRIPTION
        This is the canonical platform key used in tools.lock.psd1. The OS
        component is one of windows|linux|darwin and the architecture
        component is one of amd64|arm64. Any other combination throws
        PlatformNotSupportedException.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $os = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'darwin' } else { $null }
    if (-not $os) {
        throw [System.PlatformNotSupportedException]::new(
            'Cannot determine OS: $IsWindows, $IsLinux, $IsMacOS are all false.')
    }

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    $archTag = switch ($arch) {
        ([System.Runtime.InteropServices.Architecture]::X64) { 'amd64' }
        ([System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' }
        default {
            throw [System.PlatformNotSupportedException]::new(
                "Unsupported architecture: $arch. Avm only ships amd64 and arm64 tool binaries.")
        }
    }

    return "$os-$archTag"
}
