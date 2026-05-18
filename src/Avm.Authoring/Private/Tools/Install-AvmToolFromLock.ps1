function Install-AvmToolFromLock {
    <#
    .SYNOPSIS
        Install a single tool entry from a parsed tools.lock into the cache.

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

    if (-not $Tool.sha256.ContainsKey($Platform)) {
        throw [AvmToolException]::new(
            "Tool '$($Tool.name)' has no sha256 entry for platform '$Platform'.",
            'AVM1012')
    }

    $toolsRoot = Get-AvmFolder -Kind Tools
    $toolDir = Join-Path $toolsRoot $Tool.name
    $versionDir = Join-Path $toolDir $Tool.version
    $verified = Join-Path $versionDir '.verified'
    $entrypointName = if ($IsWindows) { "$($Tool.entrypoint).exe" } else { $Tool.entrypoint }
    $entrypointPath = Join-Path $versionDir $entrypointName

    if ((Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $entrypointPath) -and -not $Force) {
        return [pscustomobject]@{
            Name     = $Tool.name
            Version  = $Tool.version
            Platform = $Platform
            Path     = $entrypointPath
            Action   = 'cache-hit'
        }
    }

    if ($Force -and (Test-Path -LiteralPath $versionDir)) {
        Remove-Item -LiteralPath $versionDir -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $toolDir)) {
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    }

    $lockFile = Join-Path $toolDir '.lock'
    $lock = Lock-AvmToolCache -LockFile $lockFile
    try {
        if ((Test-Path -LiteralPath $verified) -and (Test-Path -LiteralPath $entrypointPath) -and -not $Force) {
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

        $stagingRoot = Join-Path $toolDir '.staging'
        if (-not (Test-Path -LiteralPath $stagingRoot)) {
            New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        }
        $stagingDir = Join-Path $stagingRoot ([Guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

        try {
            $archiveSuffix = $extToken
            $archivePath = Join-Path $stagingDir ("download" + $archiveSuffix)

            Invoke-AvmHttp -Url $url -Destination $archivePath -ExpectedSha256 $Tool.sha256[$Platform] | Out-Null
            Expand-AvmToolArchive -ArchivePath $archivePath -Archive $resolvedArchive -TargetDir $stagingDir -EntrypointBasename $Tool.entrypoint
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

            $stagedEntrypoint = Join-Path $stagingDir $entrypointName
            if (-not (Test-Path -LiteralPath $stagedEntrypoint)) {
                throw [AvmToolException]::new(
                    "Expected entrypoint '$entrypointName' missing after extracting $($Tool.name) $($Tool.version) for $Platform.",
                    'AVM1013')
            }

            $meta = [pscustomobject]@{
                name        = $Tool.name
                version     = $Tool.version
                platform    = $Platform
                url         = $url
                sha256      = $Tool.sha256[$Platform]
                archive     = $resolvedArchive
                installedAt = [DateTime]::UtcNow.ToString('o')
            }
            $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stagingDir '.meta.json') -Encoding utf8

            try {
                Move-Item -LiteralPath $stagingDir -Destination $versionDir -Force
            }
            catch [System.IO.IOException] {
                if (Test-Path -LiteralPath $verified) {
                    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
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
                Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        $lock.Dispose()
    }
}
