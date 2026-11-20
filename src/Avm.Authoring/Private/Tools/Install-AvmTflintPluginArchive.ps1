function Assert-AvmReleaseArchiveChecksum {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $ArchivePath,

        [Parameter(Mandatory)]
        [string] $ChecksumsPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($path in @($ArchivePath, $ChecksumsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("Release payload does not exist: '$path'.", $path)
        }
    }

    $archiveName = Split-Path -Path $ArchivePath -Leaf
    $checksumMatches = @(
        [System.IO.File]::ReadLines($ChecksumsPath) |
            ForEach-Object {
                $checksum = [regex]::Match($_, '^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>.+?)\s*$')
                if ($checksum.Success -and $checksum.Groups['name'].Value -ceq $archiveName) {
                    $checksum.Groups['hash'].Value
                }
            }
    )
    if ($checksumMatches.Count -ne 1) {
        throw [System.IO.InvalidDataException]::new(
            "Checksums manifest must contain exactly one SHA256 entry for '$archiveName'.")
    }

    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $checksumMatches[0].ToLowerInvariant()
    if ($actual -cne $expected) {
        throw [System.IO.InvalidDataException]::new(
            "SHA256 mismatch for '$archiveName'. Expected $expected but found $actual.")
    }

    return $true
}

function Install-AvmTflintPluginArchive {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ArchivePath,

        [Parameter(Mandatory)]
        [string] $ChecksumsPath,

        [Parameter(Mandatory)]
        [string] $PluginCacheDirectory,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$')]
        [string] $Version
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Assert-AvmReleaseArchiveChecksum -ArchivePath $ArchivePath -ChecksumsPath $ChecksumsPath | Out-Null

    $pluginName = 'tflint-ruleset-avm'
    $entrypoint = if ($IsWindows) { "$pluginName.exe" } else { $pluginName }
    $pluginRoot = Join-Path $PluginCacheDirectory 'github.com'
    $pluginRoot = Join-Path $pluginRoot 'Azure'
    $pluginRoot = Join-Path $pluginRoot $pluginName
    $destination = Join-Path $pluginRoot $Version

    $lock = Lock-AvmToolCache -LockFile (Join-Path $pluginRoot '.lock')
    try {
        $existingEntrypoint = Join-Path $destination $entrypoint
        if (Test-Path -LiteralPath $existingEntrypoint -PathType Leaf) {
            return [pscustomobject]@{
                Path   = $existingEntrypoint
                Action = 'cache-hit'
            }
        }
        if (Test-Path -LiteralPath $destination) {
            throw [System.IO.IOException]::new(
                "TFLint plugin cache entry '$destination' exists but does not contain '$entrypoint'.")
        }

        $stagingRoot = Join-Path $pluginRoot '.staging'
        $staging = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            Expand-AvmToolArchive `
                -ArchivePath $ArchivePath `
                -Archive 'zip' `
                -TargetDir $staging `
                -EntrypointBasename $pluginName

            $stagedEntrypoint = Join-Path $staging $entrypoint
            if (-not (Test-Path -LiteralPath $stagedEntrypoint -PathType Leaf)) {
                throw [System.IO.InvalidDataException]::new(
                    "TFLint plugin archive did not contain '$entrypoint' at its root.")
            }
            if ($IsWindows) {
                $signature = Get-AuthenticodeSignature -FilePath $stagedEntrypoint
                if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                    throw [System.IO.InvalidDataException]::new(
                        "TFLint plugin signature is not valid: $($signature.Status).")
                }
            }
            else {
                & chmod 755 $stagedEntrypoint 2>$null
            }

            Move-Item -LiteralPath $staging -Destination $destination -ErrorAction Stop
            return [pscustomobject]@{
                Path   = Join-Path $destination $entrypoint
                Action = 'installed'
            }
        }
        finally {
            if (Test-Path -LiteralPath $staging) {
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue -ProgressAction SilentlyContinue
            }
        }
    }
    finally {
        $lock.Dispose()
    }
}
