function Invoke-AvmHttp {
    <#
    .SYNOPSIS
        Download a URL to a local file, verifying SHA256 atomically.

    .DESCRIPTION
        The only download primitive used by the tool resolver. Pins TLS 1.2+,
        honours $env:AVM_OFFLINE=1 (refuses any HTTP), and rewrites the host
        when $env:AVM_MIRROR is set. Always writes to '<Destination>.partial'
        first, verifies SHA256, and only then renames to the final path.

        For test fixtures, file:// URLs are accepted and short-circuit the
        network path while still going through the SHA verification.

    .PARAMETER Url
        Source URL. Must start with https:// (or file:// for tests).

    .PARAMETER Destination
        Absolute path to write the downloaded artifact to.

    .PARAMETER ExpectedSha256
        64-char lowercase hex SHA256. A mismatch throws SecurityException and
        deletes the .partial file.

    .PARAMETER TimeoutSec
        Network read timeout (default 300s). Ignored for file:// URLs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [int] $TimeoutSec = 300
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not ($Url.StartsWith('https://') -or $Url.StartsWith('file://'))) {
        throw [System.ArgumentException]::new(
            "Invoke-AvmHttp only accepts https:// (or file:// for tests). Got: $Url")
    }
    if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$') {
        throw [System.ArgumentException]::new(
            "ExpectedSha256 must be 64-char lowercase hex. Got: $ExpectedSha256")
    }

    $mirror = if (Test-Path Env:\AVM_MIRROR) { $env:AVM_MIRROR } else { $null }
    $effectiveUrl = Resolve-AvmMirrorUrl -Source $Url -Mirror $mirror
    if ($effectiveUrl -cne $Url) {
        Write-Verbose "AVM_MIRROR rewrite: $Url -> $effectiveUrl"
    }

    $offline = if (Test-Path Env:\AVM_OFFLINE) { $env:AVM_OFFLINE -eq '1' } else { $false }
    if ($offline -and $effectiveUrl.StartsWith('https://')) {
        throw [AvmConfigurationException]::new(
            "AVM_OFFLINE=1: refusing to download $effectiveUrl")
    }

    $destDir = Split-Path -Parent $Destination
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    if ($effectiveUrl.StartsWith('file://')) {
        $localSource = [Uri]::new($effectiveUrl).LocalPath
        Copy-Item -LiteralPath $localSource -Destination $partial -Force
    }
    else {
        # TLS 1.2+ pin. Tls13 may not be defined on older .NET targets, so
        # combine defensively.
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        $protocols = $tls12
        $tls13Member = [System.Net.SecurityProtocolType].GetField('Tls13')
        if ($null -ne $tls13Member) {
            $protocols = $tls12 -bor [System.Net.SecurityProtocolType]::Tls13
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols

        Invoke-WebRequest -Uri $effectiveUrl -OutFile $partial -TimeoutSec $TimeoutSec -UseBasicParsing | Out-Null
    }

    $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw [AvmToolException]::new(
            "SHA256 mismatch downloading $effectiveUrl. Expected: $expected. Actual: $actual.",
            'AVM1011')
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    return $Destination
}
