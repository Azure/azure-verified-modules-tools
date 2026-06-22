function Resolve-AvmPinnedAsset {
    <#
    .SYNOPSIS
        Materialise a single pinned asset descriptor into the per-user cache.

    .DESCRIPTION
        Given an asset descriptor (the shape Read-AvmAssetConfig.Assets[<name>]
        returns) plus its asset Name, ensures the referenced archive is
        downloaded, SHA-verified, extracted, and available under

            <Get-AvmFolder Cache>/assets/<name>/<sha256-prefix12>/

        The 12-hex prefix (first 12 chars of the lowercase SHA256) keeps cache
        paths short on Windows per spec §6 (260-char budget). The full 64-char
        SHA is still pinned by the descriptor, verified by Invoke-AvmHttp, and
        preserved in .meta.json — only the on-disk directory name is truncated.

        The install pipeline mirrors Install-AvmToolFromLock: cache-hit
        short-circuit -> cross-process lock -> stage under .staging/<uuid>/
        -> Invoke-AvmHttp (download + SHA verify) -> Expand-AvmToolArchive
        -> optional Path subdir verification -> atomic Move-Item to final
        dir -> .meta.json + .verified marker -> unlock.

        Archive type is inferred from the source URL extension:
            *.zip                  -> zip
            *.tar.gz | *.tgz       -> tar.gz

        This slice (2/2 of the pinned-asset feature) only supports
        sha256-pinned archives. Ref-only assets and type=git assets throw
        AvmConfigurationException so callers see a clean "not yet
        supported" message; both are tracked for follow-up slices.

    .PARAMETER Name
        The asset name. Used for the cache subdirectory and diagnostics.

    .PARAMETER Asset
        The pscustomobject descriptor returned by Read-AvmAssetConfig.
        Required properties: Source. Conditionally required: Sha256.
        Optional: Ref, Path, Type.

    .PARAMETER AllowFileUrls
        Forwarded to Invoke-AvmHttp. Permits file:// sources for fixtures.

    .PARAMETER Force
        If set, blow away any cached materialisation and re-install.

    .OUTPUTS
        [pscustomobject] with members:
            Name     : asset name
            Sha256   : the cache key
            Ref      : descriptor Ref (may be $null)
            Path     : absolute on-disk root of the materialised asset.
                       If the descriptor specifies a sub-Path, that subdir
                       is appended.
            Action   : 'cache-hit' | 'installed' | 'race-loss'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [pscustomobject] $Asset,

        [switch] $AllowFileUrls,

        [switch] $Force
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw [System.ArgumentException]::new(
            'Resolve-AvmPinnedAsset: Name must be a non-empty string.', 'Name')
    }

    $source = if ($Asset.PSObject.Properties['Source']) { [string]$Asset.Source } else { $null }
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw [AvmConfigurationException]::new(
            "Resolve-AvmPinnedAsset: asset '$Name' is missing 'Source'.",
            'AVM1004')
    }

    $type = if ($Asset.PSObject.Properties['Type']) { [string]$Asset.Type } else { $null }
    if ($type -eq 'git') {
        throw [AvmConfigurationException]::new(
            "Resolve-AvmPinnedAsset: asset '$Name' uses type='git'; only archive assets are supported in this slice (slice 2/2 of the pinned-asset feature).",
            'AVM1004')
    }

    $sha = if ($Asset.PSObject.Properties['Sha256']) { [string]$Asset.Sha256 } else { $null }
    if ([string]::IsNullOrWhiteSpace($sha)) {
        throw [AvmConfigurationException]::new(
            "Resolve-AvmPinnedAsset: asset '$Name' has no 'Sha256'. Ref-only materialisation is not yet supported; pin a sha256 (slice 2/2 of the pinned-asset feature).",
            'AVM1004')
    }
    if ($sha -cnotmatch '^[0-9a-f]{64}$') {
        throw [AvmConfigurationException]::new(
            "Resolve-AvmPinnedAsset: asset '$Name' Sha256 must be 64-char lowercase hex.",
            'AVM1004')
    }

    $archiveKind = $null
    $extSuffix = $null
    $lower = $source.ToLowerInvariant()
    if ($lower.EndsWith('.zip')) {
        $archiveKind = 'zip'
        $extSuffix = '.zip'
    }
    elseif ($lower.EndsWith('.tar.gz')) {
        $archiveKind = 'tar.gz'
        $extSuffix = '.tar.gz'
    }
    elseif ($lower.EndsWith('.tgz')) {
        $archiveKind = 'tar.gz'
        $extSuffix = '.tgz'
    }
    else {
        throw [AvmConfigurationException]::new(
            "Resolve-AvmPinnedAsset: asset '$Name' source URL '$source' has an unsupported archive extension; expected .zip, .tar.gz, or .tgz.",
            'AVM1004')
    }

    $ref = if ($Asset.PSObject.Properties['Ref']) { [string]$Asset.Ref } else { $null }
    $subPath = if ($Asset.PSObject.Properties['Path']) { [string]$Asset.Path } else { $null }

    $cacheRoot = Get-AvmFolder -Kind Cache
    $assetsRoot = Join-Path $cacheRoot 'assets'
    $assetDir = Join-Path $assetsRoot $Name
    # Spec §6 line 220: use a 12-hex prefix of the SHA256 as the content-addressed
    # segment, not the full 64-char hash. Keeps Windows paths within budget; the
    # full SHA is still validated by Invoke-AvmHttp and recorded in .meta.json.
    $shaPrefix = $sha.Substring(0, 12)
    $versionDir = Join-Path $assetDir $shaPrefix
    $verified = Join-Path $versionDir '.verified'

    $resolvedPath = if ([string]::IsNullOrWhiteSpace($subPath)) { $versionDir } else { Join-Path $versionDir $subPath }

    if ((Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $resolvedPath) -and -not $Force) {
        return [pscustomobject][ordered]@{
            Name   = $Name
            Sha256 = $sha
            Ref    = $ref
            Path   = $resolvedPath
            Action = 'cache-hit'
        }
    }

    if (-not $PSCmdlet.ShouldProcess($versionDir, "Resolve pinned asset '$Name'")) {
        return $null
    }

    if ($Force -and (Test-Path -LiteralPath $versionDir)) {
        Remove-Item -LiteralPath $versionDir -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $assetDir)) {
        New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
    }

    $lockFile = Join-Path $assetDir '.lock'
    $lock = Lock-AvmToolCache -LockFile $lockFile
    try {
        if ((Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $resolvedPath) -and -not $Force) {
            return [pscustomobject][ordered]@{
                Name   = $Name
                Sha256 = $sha
                Ref    = $ref
                Path   = $resolvedPath
                Action = 'cache-hit'
            }
        }

        $stagingRoot = Join-Path $assetDir '.staging'
        if (-not (Test-Path -LiteralPath $stagingRoot)) {
            New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        }
        $stagingDir = Join-Path $stagingRoot ([Guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

        try {
            $archivePath = Join-Path $stagingDir ("download" + $extSuffix)

            $httpParams = @{
                Url            = $source
                Destination    = $archivePath
                ExpectedSha256 = $sha
            }
            if ($AllowFileUrls -and $source.StartsWith('file://')) {
                # Invoke-AvmHttp accepts file:// natively; no extra flag needed,
                # but we still gate it via -AllowFileUrls on this function so
                # callers must opt in explicitly (matches Test-AvmAssetConfig).
            }
            elseif ($source.StartsWith('file://') -and -not $AllowFileUrls) {
                throw [AvmConfigurationException]::new(
                    "Resolve-AvmPinnedAsset: asset '$Name' uses file:// source; pass -AllowFileUrls to permit it.",
                    'AVM1004')
            }
            Invoke-AvmHttp @httpParams | Out-Null

            Expand-AvmToolArchive -ArchivePath $archivePath -Archive $archiveKind -TargetDir $stagingDir -EntrypointBasename $Name
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

            if (-not [string]::IsNullOrWhiteSpace($subPath)) {
                $stagedSub = Join-Path $stagingDir $subPath
                if (-not (Test-Path -LiteralPath $stagedSub)) {
                    throw [AvmConfigurationException]::new(
                        "Resolve-AvmPinnedAsset: asset '$Name' declared Path '$subPath' but it does not exist after extraction.",
                        'AVM1004')
                }
            }

            $meta = [pscustomobject][ordered]@{
                name        = $Name
                source      = $source
                sha256      = $sha
                ref         = $ref
                path        = $subPath
                archive     = $archiveKind
                installedAt = [DateTime]::UtcNow.ToString('o')
            }
            $metaPath = Join-Path $stagingDir '.meta.json'
            $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaPath -Encoding utf8

            try {
                Move-Item -LiteralPath $stagingDir -Destination $versionDir -Force
            }
            catch [System.IO.IOException] {
                if (Test-Path -LiteralPath $verified) {
                    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
                    return [pscustomobject][ordered]@{
                        Name   = $Name
                        Sha256 = $sha
                        Ref    = $ref
                        Path   = $resolvedPath
                        Action = 'race-loss'
                    }
                }
                throw
            }

            New-Item -ItemType File -Path $verified -Force | Out-Null

            return [pscustomobject][ordered]@{
                Name   = $Name
                Sha256 = $sha
                Ref    = $ref
                Path   = $resolvedPath
                Action = 'installed'
            }
        }
        finally {
            if (Test-Path -LiteralPath $stagingDir) {
                Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        $lock.Dispose()
    }
}
