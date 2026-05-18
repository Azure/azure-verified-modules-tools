function Resolve-AvmTool {
    <#
    .SYNOPSIS
        Resolve the on-disk path to a managed tool's entrypoint binary.

    .DESCRIPTION
        Engine code calls this helper to obtain a usable path to bicep,
        terraform, tflint, etc. before invoking the binary. The resolution
        order mirrors Get-AvmTool's status logic:

          1. Cached + verified under <Tools>/<name>/<version>/<entry>[.exe].
          2. On PATH and reporting the lock-pinned version (-AllowPathFallback).

        On miss, throws AvmToolException with a remediation hint pointing
        the caller at `avm tool install <name>` (or `Install-AvmTool`).

        This helper deliberately does not auto-install. Auto-install is
        a separate, opt-in policy decision (--auto-install / CI heuristic
        per the consolidation plan), to be wired by the verb dispatcher.

    .PARAMETER Name
        The tool name as it appears in tools.lock.psd1 (lowercase).

    .PARAMETER LockPath
        Override the bundled lock file. For tests.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved binary that self-reports the
        lock-pinned version. Defaults to off (engines should prefer the
        managed cache for reproducibility).

    .PARAMETER AllowFileUrls
        Test-only escape hatch passed through to Read-AvmToolsLock.

    .OUTPUTS
        pscustomobject with: Name, Version, Platform, Source, Path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [string] $LockPath,

        [switch] $AllowPathFallback,

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

    $tool = $lock.tools | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $tool) {
        throw [System.ArgumentException]::new(
            "Unknown tool '$Name' (not in tools.lock).")
    }

    $platform = Get-AvmToolPlatform

    if ($tool.ContainsKey('unsupportedPlatforms') -and (@($tool.unsupportedPlatforms) -ccontains $platform)) {
        throw [AvmToolException]::new(
            ("Tool '{0}' does not ship a release for '{1}'." -f $tool.name, $platform),
            'AVM1012')
    }

    $toolsRoot = Get-AvmFolder -Kind Tools
    $versionDir = Join-Path (Join-Path $toolsRoot $tool.name) $tool.version
    $entrypointName = if ($IsWindows) { "$($tool.entrypoint).exe" } else { $tool.entrypoint }
    $entrypoint = Join-Path $versionDir $entrypointName
    $verified = Join-Path $versionDir '.verified'

    if ((Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $entrypoint)) {
        return [pscustomobject][ordered]@{
            Name     = $tool.name
            Version  = $tool.version
            Platform = $platform
            Source   = 'cache'
            Path     = $entrypoint
        }
    }

    if ($AllowPathFallback) {
        $hit = Find-AvmToolOnPath -Entrypoint $tool.entrypoint -ExpectedVersion $tool.version
        if ($hit -and $hit.Matches) {
            return [pscustomobject][ordered]@{
                Name     = $tool.name
                Version  = $tool.version
                Platform = $platform
                Source   = 'path'
                Path     = $hit.Path
            }
        }
    }

    throw [AvmToolException]::new(
        ("Tool '{0}' (version {1}) is not installed. Run: avm tool install {0}" -f $tool.name, $tool.version),
        'AVM1014')
}
