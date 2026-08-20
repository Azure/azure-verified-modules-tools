function Resolve-AvmTflintAvmSchemaSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable] $Pins
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Pins) {
        $Pins = Read-AvmPins
    }
    if (-not $Pins.ContainsKey('tflintAvmSchemaSnapshot')) {
        return $null
    }

    $snapshot = $Pins.tflintAvmSchemaSnapshot
    if (-not [bool]$snapshot.enabled) {
        return $null
    }
    if ([bool]$snapshot.placeholder) {
        throw [AvmConfigurationException]::new(
            'The configured TFLint AVM schema snapshot is a placeholder. Replace it with an immutable URL and SHA256 before enabling it.',
            'AVM1004')
    }

    $name = 'tflint-avm-schema'
    $version = [string]$snapshot.version
    $source = [string]$snapshot.url
    $sha = [string]$snapshot.sha256
    $cacheRoot = Get-AvmFolder -Kind Cache
    $assetRoot = Join-Path $cacheRoot $name
    $versionDir = Join-Path $assetRoot $sha
    $snapshotPath = Join-Path $versionDir 'snapshot.json'
    $verifiedPath = Join-Path $versionDir '.verified'
    $metaPath = Join-Path $versionDir '.meta.json'

    $isCacheHit = {
        if (
            -not (Test-Path -LiteralPath $verifiedPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $snapshotPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $metaPath -PathType Leaf)
        ) {
            return $false
        }

        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
            return [string]$meta.sha256 -ceq $sha
        }
        catch [System.Management.Automation.RuntimeException] {
            return $false
        }
    }

    if (& $isCacheHit) {
        return [pscustomobject][ordered]@{
            Version = $version
            Sha256  = $sha
            Path    = $snapshotPath
            Action  = 'cache-hit'
        }
    }

    if (-not (Test-Path -LiteralPath $assetRoot)) {
        New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
    }
    $lock = Lock-AvmToolCache -LockFile (Join-Path $assetRoot '.lock')
    try {
        if (& $isCacheHit) {
            return [pscustomobject][ordered]@{
                Version = $version
                Sha256  = $sha
                Path    = $snapshotPath
                Action  = 'cache-hit'
            }
        }

        if (Test-Path -LiteralPath $versionDir) {
            Remove-Item -LiteralPath $versionDir -Recurse -Force
        }

        $stagingRoot = Join-Path $assetRoot '.staging'
        $stagingDir = Join-Path $stagingRoot ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
        try {
            $stagedSnapshot = Join-Path $stagingDir 'snapshot.json'
            try {
                Invoke-AvmHttp -Url $source -Destination $stagedSnapshot -ExpectedSha256 $sha | Out-Null
            }
            catch [AvmConfigurationException] {
                throw [AvmConfigurationException]::new(
                    "TFLint AVM schema snapshot $version could not be resolved: $($_.Exception.Message) " +
                    "Preload the exact pin by running 'avm lint' once with AVM_OFFLINE unset.",
                    $_.Exception)
            }
            catch [AvmToolException] {
                throw [AvmConfigurationException]::new(
                    "TFLint AVM schema snapshot $version could not be verified: $($_.Exception.Message) " +
                    "Preload the exact pin by running 'avm lint' once with AVM_OFFLINE unset.",
                    $_.Exception)
            }

            [pscustomobject][ordered]@{
                version     = $version
                source      = $source
                sha256      = $sha
                installedAt = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stagingDir '.meta.json') -Encoding utf8NoBOM

            Move-Item -LiteralPath $stagingDir -Destination $versionDir
            New-Item -ItemType File -Path $verifiedPath -Force | Out-Null

            return [pscustomobject][ordered]@{
                Version = $version
                Sha256  = $sha
                Path    = $snapshotPath
                Action  = 'installed'
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
