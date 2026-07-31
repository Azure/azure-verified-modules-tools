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

        On a cache miss the helper installs the pinned tool on demand
        through the verified Install-AvmToolFromPins pipeline (SHA256 +
        atomic rename + cross-process lock, honouring AVM_HOME), then
        re-resolves. This keeps `avm` self-sufficient: consumers never
        have to run `avm tool install` first, locally or in CI.

        Set AVM_NO_AUTO_INSTALL=1 (or pass -NoAutoInstall) to disable
        implicit installation for locked-down or air-gapped environments;
        resolution then hard-fails with a remediation hint pointing at
        `avm tool install <name>`.

    .PARAMETER Name
        The tool name as it appears in avm.pins.jsonc (lowercase).

    .PARAMETER PinsPath
        Override the bundled lock file. For tests.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved binary that self-reports the
        lock-pinned version. Defaults to off (engines should prefer the
        managed cache for reproducibility).

    .PARAMETER NoAutoInstall
        Disable on-demand installation of a missing pinned tool. Equivalent
        to AVM_NO_AUTO_INSTALL=1. Resolution then hard-fails instead of
        installing. For locked-down environments and tests.

    .PARAMETER AllowFileUrls
        Test-only escape hatch passed through to Read-AvmPins.

    .OUTPUTS
        pscustomobject with: Name, Version, Platform, Source, Path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [string] $PinsPath,

        [switch] $AllowPathFallback,

        [switch] $NoAutoInstall,

        [Parameter(DontShow)]
        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lock = if ($PinsPath) {
        Read-AvmPins -Path $PinsPath -AllowFileUrls:$AllowFileUrls
    }
    else {
        Read-AvmPins
    }

    $tool = $lock.tools | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $tool) {
        throw [System.ArgumentException]::new(
            "Unknown tool '$Name' (not in avm.pins).")
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

    if (Test-AvmAutoInstallDisabled -Explicit:$NoAutoInstall) {
        throw [AvmToolException]::new(
            ("Tool '{0}' (version {1}) is not installed and automatic installation is disabled (AVM_NO_AUTO_INSTALL). Run: avm tool install {0}" -f $tool.name, $tool.version),
            'AVM1014')
    }

    Write-Information ("Installing {0} {1} ({2})..." -f $tool.name, $tool.version, $platform) -InformationAction Continue
    $installed = Install-AvmToolFromPins -Tool $tool -Platform $platform

    if (-not ((Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $entrypoint))) {
        throw [AvmToolException]::new(
            ("Tool '{0}' (version {1}) could not be installed automatically. Run: avm tool install {0}" -f $tool.name, $tool.version),
            'AVM1014')
    }

    $source = if ($installed -and $installed.Action -eq 'installed') { 'installed' } else { 'cache' }
    return [pscustomobject][ordered]@{
        Name     = $tool.name
        Version  = $tool.version
        Platform = $platform
        Source   = $source
        Path     = $entrypoint
    }
}
