function Get-AvmTool {
    <#
    .SYNOPSIS
        List or query managed tools from the tools.lock manifest.

    .DESCRIPTION
        With no -Name, returns one pscustomobject per tool in the lock. With
        one or more -Name values, returns only the matching tool(s).

        Each result has a 'Status' field set per spec section 10 lookup order:
          - 'installed'        : the lock-pinned version is in the user cache
                                 and the .verified marker is present.
          - 'installed-on-path': not in the cache, but the entrypoint is on
                                 PATH and self-reports the lock-pinned version.
          - 'outdated-on-path' : on PATH, but the version does not match the
                                 lock.
          - 'missing'          : neither cached nor on PATH.

        Routed by the dispatcher:
            avm tool list           -> Get-AvmTool
            avm tool which <name>   -> Get-AvmTool -Name <name>

    .PARAMETER Name
        One or more tool names (lowercase). Case-sensitive against the lock.

    .PARAMETER LockPath
        Override the bundled Resources/tools.lock.psd1. Intended for tests.

    .PARAMETER NoPathFallback
        Skip the PATH lookup. Useful in unit tests so that the host system's
        PATH cannot influence the result. Production callers leave it off.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string[]] $Name,

        [string] $LockPath,

        [switch] $NoPathFallback,

        # Test-only escape hatch (see Test-AvmToolsLock). Hidden from help
        # and tab-completion so it does not appear in the production surface.
        [Parameter(DontShow)]
        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lock = if ($LockPath) {
        Read-AvmToolsLock -Path $LockPath -AllowFileUrls:$AllowFileUrls
    }
    else {
        Read-AvmToolsLock
    }
    $tools = @($lock.tools)
    $platform = Get-AvmToolPlatform
    $toolsRoot = Get-AvmFolder -Kind Tools

    if ($Name) {
        $requested = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($n in $Name) { [void]$requested.Add($n) }
        $tools = $tools | Where-Object { $requested.Contains($_.name) }
        $tools = @($tools)

        $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($t in $tools) { [void]$found.Add($t.name) }
        $missing = $Name | Where-Object { -not $found.Contains($_) }
        if ($missing) {
            throw [System.ArgumentException]::new(
                "Unknown tool(s) in lock: $($missing -join ', ').")
        }
    }

    foreach ($t in $tools) {
        $versionDir = Join-Path (Join-Path $toolsRoot $t.name) $t.version
        $entrypointName = if ($IsWindows) { "$($t.entrypoint).exe" } else { $t.entrypoint }
        $entrypoint = Join-Path $versionDir $entrypointName
        $verified = Join-Path $versionDir '.verified'
        $cached = (Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $entrypoint)

        $status = 'missing'
        $path = $null
        $source = $null
        $detectedVersion = $null

        if ($cached) {
            $status = 'installed'
            $path = $entrypoint
            $source = 'cache'
        }
        elseif (-not $NoPathFallback) {
            $hit = Find-AvmToolOnPath -Entrypoint $t.entrypoint -ExpectedVersion $t.version
            if ($hit) {
                $path = $hit.Path
                $source = 'path'
                $detectedVersion = $hit.DetectedVersion
                if ($hit.Matches) {
                    $status = 'installed-on-path'
                }
                else {
                    $status = 'outdated-on-path'
                    Write-Warning ("PATH '$($t.entrypoint)' reports '{0}' but lock pins '{1}'." -f
                        ($detectedVersion ?? '<unknown>'), $t.version)
                }
            }
        }

        [pscustomobject][ordered]@{
            Name            = $t.name
            Version         = $t.version
            Platform        = $platform
            Status          = $status
            Path            = $path
            Source          = $source
            DetectedVersion = $detectedVersion
        }
    }
}
