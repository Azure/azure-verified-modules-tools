function Test-AvmDisableSentinel {
    <#
    .SYNOPSIS
        Walk up from $Path looking for a .avm/.disable sentinel file.

    .DESCRIPTION
        Implements the disable-switch defined in the implementation spec
        section 8. Returns the path to the sentinel file when found, or
        $null otherwise. Public callers (the dispatcher) translate the
        non-null return into an AvmConfigurationException.

        The walk stops at the filesystem root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Path) {
        $Path = (Get-Location).ProviderPath
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $dir = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ((Get-Item -LiteralPath $dir).PSIsContainer -eq $false) {
        $dir = Split-Path -Parent $dir
    }

    while ($dir) {
        $sentinel = Join-Path (Join-Path $dir '.avm') '.disable'
        if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
            return $sentinel
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}
