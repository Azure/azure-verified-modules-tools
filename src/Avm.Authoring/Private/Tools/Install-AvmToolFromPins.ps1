function Install-AvmToolFromPins {
    <#
    .SYNOPSIS
        Install a single tool entry from a parsed avm.pins into the cache.

    .DESCRIPTION
        Internal worker invoked by the public Install-AvmTool. Performs the
        full install pipeline for one (tool, platform) pair:

            1. Resolve cache target '<Data>/tools/<name>/<version>/'.
            2. If '.verified' marker exists and -Force not set, return path.
            3. Acquire cross-process lock under '<Data>/tools/<name>/.lock'.
            4. Re-check '.verified' (another process may have raced ahead).
            5. Stage download into '<Data>/tools/<name>/.staging/<uuid>/'.
            6. Verify SHA256 (in Invoke-AvmHttp).
            7. Expand archive into the staging dir.
            8. Move-Item staging dir to final '<version>/' (atomic rename).
               If the rename loses a race, discard staging and use the
               existing dir.
            9. Write .meta.json and touch .verified marker.
           10. Release lock; return final path.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm.pins.jsonc manifest, which holds many pins.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Tool,
        [Parameter(Mandatory)] [string] $Platform,
        [switch] $Force
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Tool.ContainsKey('unsupportedPlatforms') -and (@($Tool.unsupportedPlatforms) -ccontains $Platform)) {
        throw [AvmToolException]::new(
            "Tool '$($Tool.name)' does not ship a release for '$Platform'.",
            'AVM1012')
    }

    $overridden = $Tool.ContainsKey('versionOverride')
    if (-not $overridden -and -not $Tool.sha256.ContainsKey($Platform)) {
        throw [AvmToolException]::new(
            "Tool '$($Tool.name)' has no sha256 entry for platform '$Platform'.",
            'AVM1012')
    }

    $cache = Get-AvmToolCacheEntry -Tool $Tool -Platform $Platform
    $versionDir = $cache.Directory
    $toolDir = Split-Path -Path $versionDir -Parent
    $verified = $cache.Marker
    $entrypointPath = $cache.Path
    $entrypointName = Split-Path -Path $entrypointPath -Leaf
    $isModule = $Tool.ContainsKey('kind') -and $Tool.kind -ceq 'powershell-module'
    Write-AvmLog ("install: target directory = {0}" -f $versionDir) -Level Verbose | Out-Null

    if ($cache.Cached -and -not $Force) {
        Write-AvmLog ("install: cache hit for {0}/{1}" -f $Tool.name, $Tool.version) -Level Verbose | Out-Null
        return [pscustomobject]@{
            Name     = $Tool.name
            Version  = $Tool.version
            Platform = $Platform
            Path     = $entrypointPath
            Action   = 'cache-hit'
        }
    }

    if (-not (Test-Path -LiteralPath $toolDir)) {
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    }

    $lockFile = Join-Path $toolDir '.lock'
    Write-AvmLog ("install: acquiring cache lock {0}" -f $lockFile) -Level Verbose | Out-Null
    $lock = Lock-AvmToolCache -LockFile $lockFile
    try {
        if ((Get-AvmToolCacheEntry -Tool $Tool -Platform $Platform).Cached -and -not $Force) {
            Write-AvmLog ("install: post-lock cache hit for {0}/{1}" -f $Tool.name, $Tool.version) -Level Verbose | Out-Null
            return [pscustomobject]@{
                Name     = $Tool.name
                Version  = $Tool.version
                Platform = $Platform
                Path     = $entrypointPath
                Action   = 'cache-hit'
            }
        }

        $osPart, $archPart = $Platform.Split('-', 2)
        $url = $Tool.urlTemplate
        $url = $url.Replace('{version}', $Tool.version)
        $url = $url.Replace('{os}', $osPart)
        $url = $url.Replace('{arch}', $archPart)
        if ($Tool.ContainsKey('platformAliases')) {
            $alias = [string]$Tool.platformAliases[$Platform]
            $url = $url.Replace('{platform}', $alias)
        }

        $resolvedArchive = $Tool.archive
        if ($Tool.ContainsKey('archives') -and $Tool.archives.ContainsKey($Platform)) {
            $resolvedArchive = [string]$Tool.archives[$Platform]
        }
        $extToken = switch ($resolvedArchive) {
            'zip' { '.zip' }
            'tar.gz' { '.tar.gz' }
            'raw' { '' }
        }
        $url = $url.Replace('{ext}', $extToken)
        Write-AvmLog ("install: source = {0}" -f $url) -Level Verbose | Out-Null
        $expectedSha256 = if ($overridden) { $null } else { $Tool.sha256[$Platform] }
        Write-AvmLog ("install: archive = {0}; expected sha256 = {1}" -f $resolvedArchive, ($expectedSha256 ?? 'disabled by tool-version-overrides.json')) -Level Verbose | Out-Null

        $stagingRoot = Join-Path $toolDir '.staging'
        if (-not (Test-Path -LiteralPath $stagingRoot)) {
            New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        }
        $stagingDir = Join-Path $stagingRoot ([Guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

        try {
            $archiveSuffix = $extToken
            $archivePath = Join-Path $stagingDir ("download" + $archiveSuffix)

            Write-AvmLog ("install: downloading to {0}" -f $archivePath) -Level Verbose | Out-Null
            $download = @{ Url = $url; Destination = $archivePath }
            if (-not $overridden) { $download.ExpectedSha256 = $expectedSha256 }
            else { $download.UnverifiedToolVersionOverride = $true }
            Invoke-AvmHttp @download | Out-Null
            Write-AvmLog ("install: expanding {0}" -f $resolvedArchive) -Level Verbose | Out-Null
            Expand-AvmToolArchive -ArchivePath $archivePath -Archive $resolvedArchive -TargetDir $stagingDir -EntrypointBasename $Tool.entrypoint
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

            $stagedEntrypoint = Join-Path $stagingDir $entrypointName
            if (-not (Test-Path -LiteralPath $stagedEntrypoint)) {
                throw [AvmToolException]::new(
                    "Expected entrypoint '$entrypointName' missing after extracting $($Tool.name) $($Tool.version) for $Platform.",
                    'AVM1013')
            }
            if ($isModule) {
                $manifest = Import-PowerShellDataFile -LiteralPath $stagedEntrypoint -ErrorAction Stop
                if ([version]$manifest.ModuleVersion -ne [version]$Tool.version) {
                    throw [AvmToolException]::new("Downloaded module '$($Tool.name)' does not declare version $($Tool.version).", 'AVM1013')
                }
            }

            $meta = [pscustomobject]@{
                name             = $Tool.name
                version          = $Tool.version
                platform         = $Platform
                url              = $url
                sha256           = $expectedSha256
                checksumVerified = -not $overridden
                urlTemplate      = $Tool.urlTemplate
                archive          = $resolvedArchive
                installedAt      = [DateTime]::UtcNow.ToString('o')
            }
            $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stagingDir '.meta.json') -Encoding utf8

            try {
                if (Test-Path -LiteralPath $versionDir) {
                    Remove-Item -LiteralPath $versionDir -Recurse -Force -ProgressAction SilentlyContinue
                }
                Move-Item -LiteralPath $stagingDir -Destination $versionDir -Force
            }
            catch [System.IO.IOException] {
                if ((Get-AvmToolCacheEntry -Tool $Tool -Platform $Platform).Cached) {
                    Write-AvmLog ("install: rename race lost for {0}/{1}; using completed cache entry" -f $Tool.name, $Tool.version) -Level Verbose | Out-Null
                    Remove-Item `
                        -LiteralPath $stagingDir `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue `
                        -ProgressAction SilentlyContinue
                    return [pscustomobject]@{
                        Name     = $Tool.name
                        Version  = $Tool.version
                        Platform = $Platform
                        Path     = $entrypointPath
                        Action   = 'race-loss'
                    }
                }
                throw
            }

            New-Item -ItemType File -Path $verified -Force | Out-Null
            Write-AvmLog ("install: verified marker written to {0}" -f $verified) -Level Verbose | Out-Null

            return [pscustomobject]@{
                Name     = $Tool.name
                Version  = $Tool.version
                Platform = $Platform
                Path     = $entrypointPath
                Action   = 'installed'
            }
        }
        finally {
            if (Test-Path -LiteralPath $stagingDir) {
                Remove-Item `
                    -LiteralPath $stagingDir `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue `
                    -ProgressAction SilentlyContinue
            }
        }
    }
    finally {
        $lock.Dispose()
    }
}
