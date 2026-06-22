function Read-AvmToolsLock {
    <#
    .SYNOPSIS
        Load and validate a tools.lock.psd1 file.

    .DESCRIPTION
        Defaults to the module-bundled lock at Resources/tools.lock.psd1.
        Pass -Path to read a fixture lock during tests. Always validates via
        Test-AvmToolsLock before returning; an invalid lock throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path,
        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Path) {
        $Path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'tools.lock.psd1')
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $lock = Import-PowerShellDataFile -LiteralPath $resolved.Path
    Test-AvmToolsLock -Lock $lock -AllowFileUrls:$AllowFileUrls | Out-Null
    return $lock
}
