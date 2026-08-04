function Get-AvmTool {
    <#
    .SYNOPSIS
        List or query managed tools from the avm.pins manifest.

    .DESCRIPTION
        With no -Name, returns one pscustomobject per tool in the lock. With
        one or more -Name values, returns only the matching tool(s).

        Each result has a 'Status' field that describes what the gauntlet will
        actually do with the tool, so `avm tool list` never disagrees with the
        engines:
          - 'installed'            : the lock-pinned version is in the user
                                     cache and the .verified marker is present.
          - 'not-installed'        : not cached; the gauntlet auto-installs the
                                     pinned version on demand (see Resolve-AvmTool).
          - 'auto-install-disabled': not cached and AVM_NO_AUTO_INSTALL is set,
                                     so the gauntlet fails until you run
                                     'avm tool install'.
          - 'installed-on-path'    : reported only with -AllowPathFallback -- the
                                     entrypoint is on PATH and self-reports the
                                     lock-pinned version.
          - 'outdated-on-path'     : reported only with -AllowPathFallback -- on
                                     PATH, but the version does not match the lock.

        The engines ignore PATH unless a verb is invoked with -AllowPathFallback,
        so this command does the same: PATH is not probed by default.

        Routed by the dispatcher:
            avm tool list           -> Get-AvmTool
            avm tool which <name>   -> Get-AvmTool -Name <name>

    .PARAMETER Name
        One or more tool names (lowercase). Case-sensitive against the lock.

    .PARAMETER PinsPath
        Override the bundled Resources/avm.pins.jsonc. Intended for tests.

    .PARAMETER AllowPathFallback
        Also probe PATH, mirroring the engines' -AllowPathFallback opt-in. Off
        by default so the reported status reflects exactly what the gauntlet
        does (cache or auto-install); PATH is never consulted otherwise.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string[]] $Name,

        [string] $PinsPath,

        [switch] $AllowPathFallback,

        # Test-only escape hatch (see Test-AvmPins). Hidden from help
        # and tab-completion so it does not appear in the production surface.
        [Parameter(DontShow)]
        [switch] $AllowFileUrls,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $lock = if ($PinsPath) {
        Read-AvmPins -Path $PinsPath -AllowFileUrls:$AllowFileUrls
    }
    else {
        Read-AvmPins
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

        $status = $null
        $path = $null
        $source = $null
        $detectedVersion = $null

        if ($cached) {
            $status = 'installed'
            $path = $entrypoint
            $source = 'cache'
        }
        elseif ($AllowPathFallback) {
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
                    Write-AvmLog ("PATH '$($t.entrypoint)' reports '{0}' but lock pins '{1}'." -f
                        ($detectedVersion ?? '<unknown>'), $t.version) -Level Warning
                }
            }
        }

        if (-not $status) {
            # Not cached (and no accepted PATH hit). Mirror the resolver: the
            # gauntlet will auto-install on demand unless that is disabled.
            $status = if (Test-AvmAutoInstallDisabled) { 'auto-install-disabled' } else { 'not-installed' }
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
